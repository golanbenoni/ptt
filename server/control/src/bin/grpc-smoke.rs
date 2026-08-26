use anyhow::Context as _;
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use futures_util::{SinkExt, StreamExt};
use hmac::{Hmac, Mac};
use sha2::Sha256;
use std::{env, time::Duration};
use tokio::sync::mpsc;
use tokio_stream::wrappers::ReceiverStream;
use tokio_tungstenite::{connect_async, tungstenite::client::IntoClientRequest};
use tonic::{client::Grpc, codegen::http::uri::PathAndQuery, transport::Endpoint, Request};
use uuid::Uuid;

#[allow(dead_code)]
mod wire {
    tonic::include_proto!("ptt.control");
}

#[allow(dead_code)]
mod media_wire {
    tonic::include_proto!("ptt.media");
}

use media_wire::{MediaDatagram, TlsMediaFrame};
use wire::{
    client_frame, server_frame, ClientFrame, ClientHello, DeviceAddress, DeviceEnvelopeBatch,
    FloorRelease, FloorToken, ProtocolVersion, RecipientDevice, ServerFrame,
};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let endpoint =
        env::var("PTT_GRPC_ENDPOINT").unwrap_or_else(|_| "http://127.0.0.1:50051".to_owned());
    let sender = identity_from_env("SENDER")?;
    let recipient = identity_from_env("RECIPIENT")?;
    let channel_id = parse_uuid_env("PTT_GRPC_CHANNEL_ID")?;
    let sender_demux = env::var("PTT_GRPC_SENDER_DEMUX")?.parse::<u32>()?;
    let sender_demux_token = URL_SAFE_NO_PAD.decode(env::var("PTT_GRPC_SENDER_DEMUX_TOKEN")?)?;
    let websocket_endpoint = env::var("PTT_WS_ENDPOINT")?;

    let channel = Endpoint::from_shared(endpoint)?.connect().await?;
    let (recipient_tx, mut recipient_stream) = connect(channel.clone(), &recipient).await?;
    expect_hello(&mut recipient_stream).await?;
    let (sender_tx, mut sender_stream) = connect(channel.clone(), &sender).await?;
    expect_hello(&mut sender_stream).await?;

    let ciphertext = b"grpc-opaque-ciphertext".to_vec();
    sender_tx
        .send(ClientFrame {
            body: Some(client_frame::Body::Envelopes(DeviceEnvelopeBatch {
                message_id: Uuid::new_v4().as_bytes().to_vec(),
                recipients: vec![RecipientDevice {
                    address: Some(recipient.address.clone()),
                    envelope: ciphertext.clone(),
                }],
                expires_at_ms: (chrono::Utc::now() + chrono::Duration::minutes(5))
                    .timestamp_millis() as u64,
            })),
        })
        .await?;
    let delivered = tokio::time::timeout(Duration::from_secs(5), recipient_stream.message())
        .await
        .context("waiting for the recipient control envelope")??
        .ok_or_else(|| anyhow::anyhow!("recipient stream ended"))?;
    match delivered.body {
        Some(server_frame::Body::Envelope(envelope)) if envelope.envelope == ciphertext => {}
        _ => anyhow::bail!("recipient did not receive the expected opaque envelope"),
    }

    let floor_token = Uuid::new_v4().as_bytes().to_vec();
    sender_tx
        .send(ClientFrame {
            body: Some(client_frame::Body::FloorToken(FloorToken {
                token: floor_token.clone(),
                sender_demux,
                channel_id: channel_id.as_bytes().to_vec(),
                priority_class: 0,
                requested_tot_ms: 2_000,
                membership_epoch: 1,
            })),
        })
        .await?;
    let decision = tokio::time::timeout(Duration::from_secs(5), sender_stream.message())
        .await
        .context("waiting for the floor decision")??
        .ok_or_else(|| anyhow::anyhow!("sender stream ended"))?;
    match decision.body {
        Some(server_frame::Body::FloorGrant(grant))
            if grant.token == floor_token && grant.sender_demux == sender_demux => {}
        _ => anyhow::bail!("sender did not receive the expected floor grant"),
    }
    let (recipient_media_tx, mut recipient_media) =
        connect_media(channel.clone(), &recipient).await?;
    let (sender_media_tx, mut sender_media) = connect_media(channel, &sender).await?;
    let mut recipient_websocket = connect_websocket(&websocket_endpoint, &recipient).await?;
    let mut sender_websocket = connect_websocket(&websocket_endpoint, &sender).await?;
    let mut packed_header = vec![0_u8; 20];
    packed_header[0] = 1;
    packed_header[1] = 0x08;
    packed_header[2..6].copy_from_slice(&sender_demux.to_be_bytes());
    packed_header[6..10].copy_from_slice(&7_u32.to_be_bytes());
    let sframe = vec![0x5a; 32];
    let hmac8 = media_hmac8(&packed_header, &sframe, &sender_demux_token)?;
    let media_frame = TlsMediaFrame {
        channel_id: channel_id.as_bytes().to_vec(),
        datagram: Some(MediaDatagram {
            packed_header,
            sframe: sframe.clone(),
            hmac8,
        }),
    };
    sender_media_tx.send(media_frame.clone()).await?;
    let received =
        match tokio::time::timeout(Duration::from_secs(5), recipient_media.message()).await {
            Ok(value) => value?.ok_or_else(|| anyhow::anyhow!("recipient media stream ended"))?,
            Err(timeout) => {
                if let Ok(Err(status)) =
                    tokio::time::timeout(Duration::from_millis(250), sender_media.message()).await
                {
                    anyhow::bail!("gRPC fallback sender was rejected: {status}");
                }
                return Err(timeout).context("waiting for gRPC fallback media");
            }
        };
    if received.channel_id != channel_id.as_bytes()
        || received.datagram.as_ref().map(|value| &value.sframe) != Some(&sframe)
    {
        anyhow::bail!("recipient did not receive the expected TLS fallback ciphertext");
    }

    let websocket_received =
        tokio::time::timeout(Duration::from_secs(5), recipient_websocket.next())
            .await
            .context("waiting for gRPC-to-WebSocket fallback media")?
            .ok_or_else(|| anyhow::anyhow!("recipient WebSocket ended"))??
            .into_data();
    if websocket_received.len() != 160
        || websocket_received[..20] != media_frame.datagram.as_ref().unwrap().packed_header
        || websocket_received[20..52] != sframe
    {
        anyhow::bail!("WebSocket recipient did not receive gRPC fallback ciphertext");
    }

    let mut invalid_websocket = connect_websocket(&websocket_endpoint, &sender).await?;
    let mut invalid_raw = vec![0_u8; 160];
    invalid_raw[0] = 1;
    invalid_raw[1] = 0x08;
    invalid_raw[2..6].copy_from_slice(&sender_demux.to_be_bytes());
    invalid_raw[6..10].copy_from_slice(&8_u32.to_be_bytes());
    invalid_raw[20..52].copy_from_slice(&sframe);
    invalid_websocket
        .send(tokio_tungstenite::tungstenite::Message::Binary(
            invalid_raw.into(),
        ))
        .await?;
    if tokio::time::timeout(Duration::from_millis(250), recipient_media.message())
        .await
        .is_ok()
    {
        anyhow::bail!("TLS fallback relayed an invalid sender HMAC");
    }
    let _ = invalid_websocket.close(None).await;

    let mut websocket_raw = vec![0_u8; 160];
    websocket_raw[0] = 1;
    websocket_raw[1] = 0x08;
    websocket_raw[2..6].copy_from_slice(&sender_demux.to_be_bytes());
    websocket_raw[6..10].copy_from_slice(&9_u32.to_be_bytes());
    websocket_raw[20..52].copy_from_slice(&sframe);
    let websocket_hmac = media_hmac8(&websocket_raw[..20], &sframe, &sender_demux_token)?;
    websocket_raw[152..].copy_from_slice(&websocket_hmac);
    sender_websocket
        .send(tokio_tungstenite::tungstenite::Message::Binary(
            websocket_raw.into(),
        ))
        .await?;
    let bridged = tokio::time::timeout(Duration::from_secs(5), recipient_media.message())
        .await
        .context("waiting for WebSocket-to-gRPC fallback media")??
        .ok_or_else(|| anyhow::anyhow!("recipient media stream ended"))?;
    let bridged_datagram = bridged
        .datagram
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("missing datagram"))?;
    if bridged.channel_id != channel_id.as_bytes()
        || bridged_datagram.sframe.len() != 132
        || bridged_datagram.sframe[..32] != sframe
    {
        anyhow::bail!("gRPC recipient did not receive WebSocket fallback ciphertext");
    }

    sender_tx
        .send(ClientFrame {
            body: Some(client_frame::Body::FloorRelease(FloorRelease {
                token: floor_token,
                sender_demux,
                channel_id: channel_id.as_bytes().to_vec(),
            })),
        })
        .await?;

    drop(recipient_tx);
    drop(sender_tx);
    drop(recipient_media_tx);
    drop(sender_media_tx);
    println!(
        "gRPC hello, floor lifecycle, and bidirectional gRPC/WebSocket TLS media fallback: ok"
    );
    Ok(())
}

fn media_hmac8(header: &[u8], sframe: &[u8], token: &[u8]) -> anyhow::Result<Vec<u8>> {
    anyhow::ensure!(header.len() == 20 && sframe.len() <= 132 && token.len() == 32);
    let mut mac = Hmac::<Sha256>::new_from_slice(token)?;
    mac.update(header);
    mac.update(sframe);
    mac.update(&vec![0_u8; 132 - sframe.len()]);
    Ok(mac.finalize().into_bytes()[..8].to_vec())
}

async fn connect_websocket(
    endpoint: &str,
    identity: &Identity,
) -> anyhow::Result<
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>,
> {
    let mut request = endpoint.into_client_request()?;
    let authorization = format!("Bearer {}", std::str::from_utf8(&identity.token)?);
    request
        .headers_mut()
        .insert("authorization", authorization.parse()?);
    Ok(connect_async(request).await?.0)
}

async fn connect_media(
    channel: tonic::transport::Channel,
    identity: &Identity,
) -> anyhow::Result<(
    mpsc::Sender<TlsMediaFrame>,
    tonic::codec::Streaming<TlsMediaFrame>,
)> {
    let (sender, receiver) = mpsc::channel(16);
    let mut grpc = Grpc::new(channel);
    grpc.ready()
        .await
        .map_err(|error| anyhow::anyhow!(error.to_string()))?;
    let mut request = Request::new(ReceiverStream::new(receiver));
    let authorization = format!("Bearer {}", std::str::from_utf8(&identity.token)?);
    request
        .metadata_mut()
        .insert("authorization", authorization.parse()?);
    let response = grpc
        .streaming(
            request,
            PathAndQuery::from_static("/ptt.media.MediaFallbackService/Tunnel"),
            tonic_prost::ProstCodec::default(),
        )
        .await?;
    Ok((sender, response.into_inner()))
}

#[derive(Clone)]
struct Identity {
    address: DeviceAddress,
    token: Vec<u8>,
}

fn identity_from_env(prefix: &str) -> anyhow::Result<Identity> {
    let aci = parse_uuid_env(&format!("PTT_GRPC_{prefix}_ACI"))?;
    let mailbox = parse_uuid_env(&format!("PTT_GRPC_{prefix}_MAILBOX_ID"))?;
    let device_id = env::var(format!("PTT_GRPC_{prefix}_DEVICE_ID"))?.parse::<u32>()?;
    let token = env::var(format!("PTT_GRPC_{prefix}_TOKEN"))?.into_bytes();
    Ok(Identity {
        address: DeviceAddress {
            aci: aci.as_bytes().to_vec(),
            device_id,
            mailbox_id: mailbox.as_bytes().to_vec(),
        },
        token,
    })
}

fn parse_uuid_env(name: &str) -> anyhow::Result<Uuid> {
    Ok(Uuid::parse_str(&env::var(name)?)?)
}

async fn connect(
    channel: tonic::transport::Channel,
    identity: &Identity,
) -> anyhow::Result<(
    mpsc::Sender<ClientFrame>,
    tonic::codec::Streaming<ServerFrame>,
)> {
    let (sender, receiver) = mpsc::channel(16);
    sender
        .send(ClientFrame {
            body: Some(client_frame::Body::Hello(ClientHello {
                version: Some(ProtocolVersion { major: 1, minor: 0 }),
                device: Some(identity.address.clone()),
                access_token: identity.token.clone(),
                push_token: Vec::new(),
                push_provider: String::new(),
            })),
        })
        .await?;
    let mut grpc = Grpc::new(channel);
    grpc.ready()
        .await
        .map_err(|error| anyhow::anyhow!(error.to_string()))?;
    let response = grpc
        .streaming(
            Request::new(ReceiverStream::new(receiver)),
            PathAndQuery::from_static("/ptt.control.ControlService/Connect"),
            tonic_prost::ProstCodec::default(),
        )
        .await?;
    Ok((sender, response.into_inner()))
}

async fn expect_hello(stream: &mut tonic::codec::Streaming<ServerFrame>) -> anyhow::Result<()> {
    let frame = tokio::time::timeout(Duration::from_secs(5), stream.message())
        .await
        .context("waiting for the server hello")??
        .ok_or_else(|| anyhow::anyhow!("stream ended before server hello"))?;
    match frame.body {
        Some(server_frame::Body::Hello(hello))
            if hello
                .version
                .as_ref()
                .is_some_and(|version| version.major == 1)
                && hello.connection_id.len() == 16
                && hello.demux_token.len() == 32 =>
        {
            Ok(())
        }
        _ => anyhow::bail!("invalid server hello"),
    }
}
