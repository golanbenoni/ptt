use std::{env, time::Duration};
use tokio::sync::mpsc;
use tokio_stream::wrappers::ReceiverStream;
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
        .await??
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
        .await??
        .ok_or_else(|| anyhow::anyhow!("sender stream ended"))?;
    match decision.body {
        Some(server_frame::Body::FloorGrant(grant))
            if grant.token == floor_token && grant.sender_demux == sender_demux => {}
        _ => anyhow::bail!("sender did not receive the expected floor grant"),
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

    let (recipient_media_tx, mut recipient_media) =
        connect_media(channel.clone(), &recipient).await?;
    let (sender_media_tx, _sender_media) = connect_media(channel, &sender).await?;
    let mut packed_header = vec![0_u8; 20];
    packed_header[0] = 1;
    packed_header[2..6].copy_from_slice(&sender_demux.to_be_bytes());
    packed_header[6..10].copy_from_slice(&7_u32.to_be_bytes());
    let sframe = vec![0x5a; 32];
    let media_frame = TlsMediaFrame {
        channel_id: channel_id.as_bytes().to_vec(),
        datagram: Some(MediaDatagram {
            packed_header,
            sframe: sframe.clone(),
            hmac8: Vec::new(),
        }),
    };
    sender_media_tx.send(media_frame).await?;
    let received = tokio::time::timeout(Duration::from_secs(5), recipient_media.message())
        .await??
        .ok_or_else(|| anyhow::anyhow!("recipient media stream ended"))?;
    if received.channel_id != channel_id.as_bytes()
        || received.datagram.as_ref().map(|value| &value.sframe) != Some(&sframe)
    {
        anyhow::bail!("recipient did not receive the expected TLS fallback ciphertext");
    }

    drop(recipient_tx);
    drop(sender_tx);
    drop(recipient_media_tx);
    drop(sender_media_tx);
    println!("gRPC hello, opaque envelope, floor lifecycle, and TLS media fallback: ok");
    Ok(())
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
        .await??
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
