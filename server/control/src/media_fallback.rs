//! Device-authenticated encrypted media transport for networks that block UDP.
//!
//! The service validates only routing metadata. SFrame ciphertext and its AAD
//! remain opaque to the server and are forwarded without modification.

use crate::{grpc::authenticate_metadata, require_device, ApiError, AppState, AuthenticatedDevice};
use axum::{
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        Query, State,
    },
    http::HeaderMap,
    response::Response as AxumResponse,
};
use futures_util::{SinkExt, StreamExt};
use hmac::{Hmac, Mac};
use serde::Deserialize;
use sha2::Sha256;
use sqlx::PgPool;
use std::{collections::HashMap, pin::Pin, sync::Arc};
use subtle::ConstantTimeEq;
use tokio::sync::{broadcast, mpsc, watch, RwLock};
use tokio_stream::{wrappers::ReceiverStream, Stream};
use tonic::{Request, Response, Status, Streaming};
use uuid::Uuid;

#[allow(dead_code)]
pub mod media_wire {
    tonic::include_proto!("ptt.media");
}

use media_wire::{
    media_fallback_service_server::MediaFallbackService, MediaDatagram, TlsMediaFrame,
};

const PACKED_HEADER_BYTES: usize = 20;
const MIN_SFRAME_BYTES: usize = 17; // one-byte header plus a 128-bit tag
const MAX_SFRAME_BYTES: usize = 132;
const RELAY_HMAC_BYTES: usize = 8;
const MEDIA_VERSION: u8 = 1;
const RAW_MEDIA_BYTES: usize = PACKED_HEADER_BYTES + 132 + RELAY_HMAC_BYTES;

#[derive(Clone)]
struct RoutedFrame {
    source_aci: Uuid,
    source_device_id: i32,
    frame: TlsMediaFrame,
}

#[derive(Clone, Default)]
pub struct MediaHub {
    channels: Arc<RwLock<HashMap<Uuid, broadcast::Sender<RoutedFrame>>>>,
}

impl MediaHub {
    async fn subscribe(&self, channel_id: Uuid) -> broadcast::Receiver<RoutedFrame> {
        let mut channels = self.channels.write().await;
        channels
            .entry(channel_id)
            .or_insert_with(|| broadcast::channel(256).0)
            .subscribe()
    }

    async fn publish(&self, channel_id: Uuid, frame: RoutedFrame) {
        let sender = {
            let mut channels = self.channels.write().await;
            channels
                .entry(channel_id)
                .or_insert_with(|| broadcast::channel(256).0)
                .clone()
        };
        let _ = sender.send(frame);
    }
}

#[derive(Clone)]
pub struct MediaFallback {
    hub: MediaHub,
    pool: PgPool,
}

impl MediaFallback {
    pub fn new(hub: MediaHub, pool: PgPool) -> Self {
        Self { hub, pool }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct WebSocketTunnelQuery {
    channel_id: Uuid,
}

/// Mobile-friendly gateway for the same opaque TLS media hub used by the gRPC service.
/// Each binary WebSocket message is one fixed 160-byte production UDP datagram.
pub(crate) async fn websocket_tunnel(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<WebSocketTunnelQuery>,
    upgrade: WebSocketUpgrade,
) -> Result<AxumResponse, ApiError> {
    let authenticated = require_device(&state.pool, &headers).await?;
    let is_member: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM memberships WHERE channel_id=$1 AND aci=$2 AND left_epoch IS NULL)",
    )
    .bind(query.channel_id)
    .bind(authenticated.aci)
    .fetch_one(&state.pool)
    .await?;
    if !is_member {
        return Err(ApiError::forbidden());
    }
    let pool = state.pool.clone();
    let hub = state.media_hub.clone();
    Ok(upgrade.on_upgrade(move |socket| {
        run_websocket(socket, pool, hub, authenticated, query.channel_id)
    }))
}

async fn run_websocket(
    socket: WebSocket,
    pool: PgPool,
    hub: MediaHub,
    authenticated: AuthenticatedDevice,
    channel_id: Uuid,
) {
    let mut subscription = hub.subscribe(channel_id).await;
    let (mut output, mut input) = socket.split();
    loop {
        tokio::select! {
            incoming = input.next() => match incoming {
                Some(Ok(Message::Binary(raw))) => {
                    let frame = match frame_from_raw(channel_id, &raw) {
                        Ok(frame) => frame,
                        Err(_) => break,
                    };
                    if route_inbound(&pool, &hub, authenticated, frame).await.is_err() { break; }
                }
                Some(Ok(Message::Ping(value))) => {
                    if output.send(Message::Pong(value)).await.is_err() { break; }
                }
                Some(Ok(Message::Close(_))) | None | Some(Err(_)) => break,
                Some(Ok(_)) => break,
            },
            routed = subscription.recv() => match routed {
                Ok(routed)
                    if routed.source_aci != authenticated.aci
                        || routed.source_device_id != authenticated.device_id =>
                {
                    let raw = match raw_from_frame(&routed.frame) {
                        Ok(raw) => raw,
                        Err(_) => break,
                    };
                    if output.send(Message::Binary(raw.into())).await.is_err() { break; }
                }
                Ok(_) | Err(broadcast::error::RecvError::Lagged(_)) => {}
                Err(broadcast::error::RecvError::Closed) => break,
            }
        }
    }
    let _ = output.send(Message::Close(None)).await;
}

fn frame_from_raw(channel_id: Uuid, raw: &[u8]) -> Result<TlsMediaFrame, Status> {
    if raw.len() != RAW_MEDIA_BYTES {
        return Err(Status::invalid_argument("INVALID_MEDIA_DATAGRAM"));
    }
    let datagram = MediaDatagram {
        packed_header: raw[..PACKED_HEADER_BYTES].to_vec(),
        sframe: raw[PACKED_HEADER_BYTES..(RAW_MEDIA_BYTES - RELAY_HMAC_BYTES)].to_vec(),
        hmac8: raw[(RAW_MEDIA_BYTES - RELAY_HMAC_BYTES)..].to_vec(),
    };
    validate_datagram(&datagram)?;
    Ok(TlsMediaFrame {
        channel_id: channel_id.as_bytes().to_vec(),
        datagram: Some(datagram),
    })
}

fn raw_from_frame(frame: &TlsMediaFrame) -> Result<Vec<u8>, Status> {
    let datagram = frame
        .datagram
        .as_ref()
        .ok_or_else(|| Status::invalid_argument("MEDIA_DATAGRAM_REQUIRED"))?;
    validate_datagram(datagram)?;
    if datagram.sframe.len() > RAW_MEDIA_BYTES - PACKED_HEADER_BYTES - RELAY_HMAC_BYTES {
        return Err(Status::invalid_argument("INVALID_MEDIA_DATAGRAM"));
    }
    let mut raw = Vec::with_capacity(RAW_MEDIA_BYTES);
    raw.extend_from_slice(&datagram.packed_header);
    raw.extend_from_slice(&datagram.sframe);
    raw.resize(RAW_MEDIA_BYTES - RELAY_HMAC_BYTES, 0);
    if datagram.hmac8.is_empty() {
        raw.resize(RAW_MEDIA_BYTES, 0);
    } else {
        raw.extend_from_slice(&datagram.hmac8);
    }
    Ok(raw)
}

type MediaStream = Pin<Box<dyn Stream<Item = Result<TlsMediaFrame, Status>> + Send>>;

#[tonic::async_trait]
impl MediaFallbackService for MediaFallback {
    type TunnelStream = MediaStream;

    async fn tunnel(
        &self,
        request: Request<Streaming<TlsMediaFrame>>,
    ) -> Result<Response<Self::TunnelStream>, Status> {
        let authenticated = authenticate_metadata(&self.pool, &request).await?;
        let memberships: Vec<Uuid> = sqlx::query_scalar(
            "SELECT channel_id FROM memberships WHERE aci=$1 AND left_epoch IS NULL ORDER BY channel_id",
        )
        .bind(authenticated.aci)
        .fetch_all(&self.pool)
        .await
        .map_err(internal)?;
        if memberships.is_empty() {
            return Err(Status::permission_denied("NO_ACTIVE_CHANNELS"));
        }

        let mut inbound = request.into_inner();
        let (outbound, receiver) = mpsc::channel(128);
        let (cancel, _) = watch::channel(false);
        for channel_id in memberships {
            let mut subscription = self.hub.subscribe(channel_id).await;
            let mut cancelled = cancel.subscribe();
            let output = outbound.clone();
            tokio::spawn(async move {
                loop {
                    tokio::select! {
                        result = subscription.recv() => match result {
                            Ok(routed)
                                if routed.source_aci != authenticated.aci
                                    || routed.source_device_id != authenticated.device_id =>
                            {
                                if output.send(Ok(routed.frame)).await.is_err() { break; }
                            }
                            Ok(_) | Err(broadcast::error::RecvError::Lagged(_)) => {}
                            Err(broadcast::error::RecvError::Closed) => break,
                        },
                        changed = cancelled.changed() => {
                            if changed.is_err() || *cancelled.borrow() { break; }
                        }
                    }
                }
            });
        }

        let hub = self.hub.clone();
        let pool = self.pool.clone();
        let output = outbound.clone();
        tokio::spawn(async move {
            while let Some(frame) = inbound.next().await {
                let result = match frame {
                    Ok(frame) => route_inbound(&pool, &hub, authenticated, frame).await,
                    Err(_) => Err(Status::invalid_argument("INVALID_MEDIA_STREAM")),
                };
                if let Err(status) = result {
                    let _ = output.send(Err(status)).await;
                    break;
                }
            }
            let _ = cancel.send(true);
        });
        drop(outbound);
        Ok(Response::new(Box::pin(ReceiverStream::new(receiver))))
    }
}

async fn route_inbound(
    pool: &PgPool,
    hub: &MediaHub,
    authenticated: AuthenticatedDevice,
    frame: TlsMediaFrame,
) -> Result<(), Status> {
    let channel_id = Uuid::from_slice(&frame.channel_id)
        .map_err(|_| Status::invalid_argument("INVALID_CHANNEL_ID"))?;
    let datagram = frame
        .datagram
        .as_ref()
        .ok_or_else(|| Status::invalid_argument("MEDIA_DATAGRAM_REQUIRED"))?;
    validate_datagram(datagram)?;
    let sender_demux = u32::from_be_bytes(
        datagram.packed_header[2..6]
            .try_into()
            .expect("validated fixed header"),
    );
    let demux_token: Option<Vec<u8>> = sqlx::query_scalar(
        "SELECT l.demux_token FROM memberships m JOIN relay_leases l ON l.channel_id=m.channel_id AND l.aci=m.aci WHERE m.channel_id=$1 AND m.aci=$2 AND m.left_epoch IS NULL AND l.device_id=$3 AND l.sender_demux=$4 AND l.expires_at > now() AND l.demux_token IS NOT NULL",
    )
    .bind(channel_id)
    .bind(authenticated.aci)
    .bind(authenticated.device_id)
    .bind(i64::from(sender_demux))
    .fetch_optional(pool)
    .await
    .map_err(internal)?;
    let Some(demux_token) = demux_token else {
        return Err(Status::permission_denied("MEDIA_ROUTE_NOT_AUTHORIZED"));
    };
    verify_sender_hmac(datagram, &demux_token)?;
    hub.publish(
        channel_id,
        RoutedFrame {
            source_aci: authenticated.aci,
            source_device_id: authenticated.device_id,
            frame,
        },
    )
    .await;
    Ok(())
}

fn verify_sender_hmac(datagram: &MediaDatagram, demux_token: &[u8]) -> Result<(), Status> {
    if demux_token.len() != 32 || datagram.hmac8.len() != RELAY_HMAC_BYTES {
        return Err(Status::permission_denied("MEDIA_AUTHENTICATION_FAILED"));
    }
    let mut mac = Hmac::<Sha256>::new_from_slice(demux_token)
        .map_err(|_| Status::permission_denied("MEDIA_AUTHENTICATION_FAILED"))?;
    mac.update(&datagram.packed_header);
    mac.update(&datagram.sframe);
    let padding = MAX_SFRAME_BYTES.saturating_sub(datagram.sframe.len());
    if padding > 0 {
        mac.update(&[0_u8; MAX_SFRAME_BYTES][..padding]);
    }
    if mac.finalize().into_bytes()[..RELAY_HMAC_BYTES]
        .ct_eq(&datagram.hmac8)
        .unwrap_u8()
        != 1
    {
        return Err(Status::permission_denied("MEDIA_AUTHENTICATION_FAILED"));
    }
    Ok(())
}

fn validate_datagram(datagram: &MediaDatagram) -> Result<(), Status> {
    let flags = datagram.packed_header.get(1).copied().unwrap_or_default();
    if datagram.packed_header.len() != PACKED_HEADER_BYTES
        || datagram.packed_header[0] != MEDIA_VERSION
        || flags & 0x08 == 0
        || flags & 0xf0 != 0
        || datagram.packed_header[14..16] != [0, 0]
        || u32::from_be_bytes(
            datagram.packed_header[2..6]
                .try_into()
                .expect("fixed header"),
        ) == 0
        || !(MIN_SFRAME_BYTES..=MAX_SFRAME_BYTES).contains(&datagram.sframe.len())
        || datagram.hmac8.len() != RELAY_HMAC_BYTES
    {
        return Err(Status::invalid_argument("INVALID_MEDIA_DATAGRAM"));
    }
    Ok(())
}

fn internal(error: impl std::fmt::Display) -> Status {
    tracing::error!(error = %error, "TLS media fallback database operation failed");
    Status::internal("INTERNAL")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn valid() -> MediaDatagram {
        let mut packed_header = vec![0_u8; PACKED_HEADER_BYTES];
        packed_header[0] = MEDIA_VERSION;
        packed_header[1] = 0x08;
        packed_header[2..6].copy_from_slice(&42_u32.to_be_bytes());
        MediaDatagram {
            packed_header,
            sframe: vec![7; MIN_SFRAME_BYTES],
            hmac8: vec![9; RELAY_HMAC_BYTES],
        }
    }

    #[test]
    fn accepts_only_bounded_sframe_datagrams_with_a_sender_demux() {
        assert!(validate_datagram(&valid()).is_ok());
        let mut value = valid();
        value.packed_header[0] = 2;
        assert!(validate_datagram(&value).is_err());
        let mut value = valid();
        value.packed_header[2..6].fill(0);
        assert!(validate_datagram(&value).is_err());
        let mut value = valid();
        value.sframe.clear();
        assert!(validate_datagram(&value).is_err());
        let mut value = valid();
        value.hmac8 = vec![0; 7];
        assert!(validate_datagram(&value).is_err());
    }

    #[test]
    fn websocket_gateway_round_trips_fixed_production_datagrams() {
        let channel_id = Uuid::new_v4();
        let mut raw = vec![0_u8; RAW_MEDIA_BYTES];
        raw[0] = MEDIA_VERSION;
        raw[1] = 0x08;
        raw[2..6].copy_from_slice(&42_u32.to_be_bytes());
        raw[PACKED_HEADER_BYTES..PACKED_HEADER_BYTES + MIN_SFRAME_BYTES].fill(7);
        raw[RAW_MEDIA_BYTES - RELAY_HMAC_BYTES..].fill(9);
        let frame = frame_from_raw(channel_id, &raw).expect("valid raw datagram");
        assert_eq!(frame.channel_id, channel_id.as_bytes());
        assert_eq!(raw_from_frame(&frame).expect("repacked datagram"), raw);
    }

    #[test]
    fn websocket_gateway_rejects_wrong_lengths_and_oversized_sframes() {
        assert!(frame_from_raw(Uuid::new_v4(), &[0; RAW_MEDIA_BYTES - 1]).is_err());
        let mut frame = TlsMediaFrame {
            channel_id: Uuid::new_v4().as_bytes().to_vec(),
            datagram: Some(valid()),
        };
        frame.datagram.as_mut().expect("datagram").sframe = vec![1; 133];
        assert!(raw_from_frame(&frame).is_err());
    }
}
