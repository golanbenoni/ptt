//! Device-authenticated encrypted media transport for networks that block UDP.
//!
//! The service validates only routing metadata. SFrame ciphertext and its AAD
//! remain opaque to the server and are forwarded without modification.

use crate::{grpc::authenticate_metadata, AuthenticatedDevice};
use sqlx::PgPool;
use std::{collections::HashMap, pin::Pin, sync::Arc};
use tokio::sync::{broadcast, mpsc, watch, RwLock};
use tokio_stream::{wrappers::ReceiverStream, Stream, StreamExt};
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
const MAX_SFRAME_BYTES: usize = 1_200;
const RELAY_HMAC_BYTES: usize = 8;
const MEDIA_VERSION: u8 = 1;

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
    let authorized: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM memberships m JOIN relay_leases l ON l.channel_id=m.channel_id AND l.aci=m.aci WHERE m.channel_id=$1 AND m.aci=$2 AND m.left_epoch IS NULL AND l.device_id=$3 AND l.sender_demux=$4 AND l.expires_at > now())",
    )
    .bind(channel_id)
    .bind(authenticated.aci)
    .bind(authenticated.device_id)
    .bind(i64::from(sender_demux))
    .fetch_one(pool)
    .await
    .map_err(internal)?;
    if !authorized {
        return Err(Status::permission_denied("MEDIA_ROUTE_NOT_AUTHORIZED"));
    }
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

fn validate_datagram(datagram: &MediaDatagram) -> Result<(), Status> {
    if datagram.packed_header.len() != PACKED_HEADER_BYTES
        || datagram.packed_header[0] != MEDIA_VERSION
        || u32::from_be_bytes(
            datagram.packed_header[2..6]
                .try_into()
                .expect("fixed header"),
        ) == 0
        || !(MIN_SFRAME_BYTES..=MAX_SFRAME_BYTES).contains(&datagram.sframe.len())
        || (!datagram.hmac8.is_empty() && datagram.hmac8.len() != RELAY_HMAC_BYTES)
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
        packed_header[2..6].copy_from_slice(&42_u32.to_be_bytes());
        MediaDatagram {
            packed_header,
            sframe: vec![7; MIN_SFRAME_BYTES],
            hmac8: Vec::new(),
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
}
