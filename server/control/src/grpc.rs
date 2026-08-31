use crate::{AppState, AuthenticatedDevice};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use chrono::{DateTime, Utc};
use prost::Message;
use ptt_server_core::{hash_secret, MAX_PREKEY_BATCH_DEVICES};
use rand::RngCore;
use sqlx::PgPool;
use std::{pin::Pin, time::Duration};
use tokio::sync::mpsc;
use tokio_stream::{wrappers::ReceiverStream, Stream, StreamExt};
use tonic::{Request, Response, Status, Streaming};
use uuid::Uuid;

#[allow(dead_code)]
pub mod wire {
    tonic::include_proto!("ptt.control");
}

use wire::{
    client_frame, control_service_server::ControlService, pre_key_service_server::PreKeyService,
    server_frame, ApiError, ClientFrame, DeviceAddress, DeviceEnvelopeBatch, Empty, ErrorCode,
    FetchPreKeysRequest, FetchPreKeysResponse, FloorSerializerDeny, FloorSerializerGrant,
    PreKeyBundle, RecipientDevice, ServerFrame, ServerHello, UploadPreKeysRequest,
};

#[derive(Clone)]
pub struct GrpcControlService {
    state: AppState,
}

#[derive(Clone)]
pub struct GrpcPreKeyService {
    state: AppState,
}

impl GrpcControlService {
    pub fn new(state: AppState) -> Self {
        Self { state }
    }
}

impl GrpcPreKeyService {
    pub fn new(state: AppState) -> Self {
        Self { state }
    }
}

type ControlStream = Pin<Box<dyn Stream<Item = Result<ServerFrame, Status>> + Send>>;

#[tonic::async_trait]
impl ControlService for GrpcControlService {
    type ConnectStream = ControlStream;

    async fn connect(
        &self,
        request: Request<Streaming<ClientFrame>>,
    ) -> Result<Response<Self::ConnectStream>, Status> {
        let mut inbound = request.into_inner();
        let first = tokio::time::timeout(Duration::from_secs(5), inbound.next())
            .await
            .map_err(|_| Status::deadline_exceeded("CLIENT_HELLO_TIMEOUT"))?
            .ok_or_else(|| Status::unauthenticated("CLIENT_HELLO_REQUIRED"))?
            .map_err(|_| Status::invalid_argument("INVALID_CLIENT_FRAME"))?;
        let hello = match first.body {
            Some(client_frame::Body::Hello(hello)) => hello,
            _ => return Err(Status::unauthenticated("CLIENT_HELLO_REQUIRED")),
        };
        let version = hello
            .version
            .ok_or_else(|| Status::failed_precondition("PROTOCOL_VERSION_REQUIRED"))?;
        if version.major != ptt_server_core::PROTOCOL_MAJOR
            || version.minor < ptt_server_core::MINIMUM_CLIENT_MINOR
        {
            return Err(Status::failed_precondition("UNSUPPORTED_VERSION"));
        }
        let address = hello
            .device
            .ok_or_else(|| Status::unauthenticated("DEVICE_ADDRESS_REQUIRED"))?;
        let authenticated =
            authenticate_hello(&self.state.pool, &address, &hello.access_token).await?;
        if !hello.push_token.is_empty() || !hello.push_provider.is_empty() {
            register_push(
                &self.state.pool,
                authenticated,
                &address,
                &hello.push_provider,
                &hello.push_token,
            )
            .await?;
        }

        let (sender, receiver) = mpsc::channel(64);
        let mut connection_id = [0_u8; 16];
        let mut demux_token = [0_u8; 32];
        rand::rng().fill_bytes(&mut connection_id);
        rand::rng().fill_bytes(&mut demux_token);
        sender
            .send(Ok(ServerFrame {
                body: Some(server_frame::Body::Hello(ServerHello {
                    version: Some(wire::ProtocolVersion {
                        major: ptt_server_core::PROTOCOL_MAJOR,
                        minor: ptt_server_core::PROTOCOL_MINOR,
                    }),
                    connection_id: connection_id.to_vec(),
                    demux_token: demux_token.to_vec(),
                    server_time_ms: Utc::now().timestamp_millis() as u64,
                })),
            }))
            .await
            .map_err(|_| Status::unavailable("CONNECTION_CLOSED"))?;

        let state = self.state.clone();
        tokio::spawn(async move {
            run_connection(state, authenticated, address, inbound, sender).await;
        });
        Ok(Response::new(Box::pin(ReceiverStream::new(receiver))))
    }
}

async fn authenticate_hello(
    pool: &PgPool,
    address: &DeviceAddress,
    access_token: &[u8],
) -> Result<AuthenticatedDevice, Status> {
    let aci = parse_uuid(&address.aci, "INVALID_ACI")?;
    let mailbox_id = parse_uuid(&address.mailbox_id, "INVALID_MAILBOX_ID")?;
    if !(1..=2).contains(&address.device_id) || access_token.is_empty() {
        return Err(Status::unauthenticated("INVALID_DEVICE"));
    }
    let token = std::str::from_utf8(access_token)
        .map_err(|_| Status::unauthenticated("INVALID_ACCESS_TOKEN"))?;
    let token_hash = hash_secret(token);
    sqlx::query_as::<_, (Uuid, i32, bool)>(
        "SELECT a.aci, d.device_id, a.is_admin FROM accounts a JOIN devices d ON d.aci = a.aci WHERE a.aci = $1 AND d.device_id = $2 AND d.mailbox_id = $3 AND d.access_token_sha256 = $4 AND d.status = 'active' AND a.disabled_at IS NULL",
    )
    .bind(aci)
    .bind(address.device_id as i32)
    .bind(mailbox_id)
    .bind(token_hash.as_slice())
    .fetch_optional(pool)
    .await
    .map_err(internal)?
    .map(|(aci, device_id, is_admin)| AuthenticatedDevice {
        aci,
        device_id,
        is_admin,
        access_token_sha256: token_hash,
    })
    .ok_or_else(|| Status::unauthenticated("UNAUTHENTICATED"))
}

async fn run_connection(
    state: AppState,
    authenticated: AuthenticatedDevice,
    address: DeviceAddress,
    mut inbound: Streaming<ClientFrame>,
    sender: mpsc::Sender<Result<ServerFrame, Status>>,
) {
    let mut poll = tokio::time::interval(Duration::from_millis(250));
    let mut auth_poll = tokio::time::interval(Duration::from_secs(2));
    loop {
        tokio::select! {
            frame = inbound.next() => match frame {
                Some(Ok(frame)) => {
                    match handle_client_frame(&state, authenticated, &address, frame).await {
                        Ok(Some(response)) => {
                            if sender.send(Ok(response)).await.is_err() { break; }
                        }
                        Ok(None) => {}
                        Err(status) => {
                            let _ = sender.send(Ok(error_frame(&status))).await;
                            break;
                        }
                    }
                }
                Some(Err(_)) | None => break,
            },
            _ = poll.tick() => match take_mailbox_item(&state.pool, authenticated, &address).await {
                Ok(Some(frame)) => {
                    if sender.send(Ok(frame)).await.is_err() { break; }
                }
                Ok(None) => {}
                Err(status) => {
                    let _ = sender.send(Err(status)).await;
                    break;
                }
            },
            _ = auth_poll.tick() => match device_still_active(&state.pool, authenticated).await {
                Ok(true) => {}
                Ok(false) => {
                    let status = Status::unauthenticated("DEVICE_REVOKED");
                    let _ = sender.send(Ok(error_frame(&status))).await;
                    break;
                }
                Err(status) => {
                    let _ = sender.send(Err(status)).await;
                    break;
                }
            },
        }
    }
}

async fn device_still_active(
    pool: &PgPool,
    authenticated: AuthenticatedDevice,
) -> Result<bool, Status> {
    sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM devices d JOIN accounts a ON a.aci=d.aci WHERE d.aci=$1 AND d.device_id=$2 AND d.access_token_sha256=$3 AND d.status='active' AND a.disabled_at IS NULL)",
    )
    .bind(authenticated.aci)
    .bind(authenticated.device_id)
    .bind(authenticated.access_token_sha256.as_slice())
    .fetch_one(pool)
    .await
    .map_err(internal)
}

async fn handle_client_frame(
    state: &AppState,
    authenticated: AuthenticatedDevice,
    address: &DeviceAddress,
    frame: ClientFrame,
) -> Result<Option<ServerFrame>, Status> {
    match frame.body {
        Some(client_frame::Body::Envelopes(batch)) => {
            enqueue_envelopes(&state.pool, authenticated, batch).await?;
            Ok(None)
        }
        Some(client_frame::Body::PushRegistration(registration)) => {
            let registration_address = registration
                .device
                .ok_or_else(|| Status::invalid_argument("DEVICE_ADDRESS_REQUIRED"))?;
            register_push(
                &state.pool,
                authenticated,
                &registration_address,
                &registration.provider,
                &registration.token,
            )
            .await?;
            Ok(None)
        }
        Some(client_frame::Body::Presence(presence)) => {
            if presence.device.as_ref() != Some(address) {
                return Err(Status::permission_denied("DEVICE_ADDRESS_MISMATCH"));
            }
            let key = format!(
                "ptt:v1:presence:{}:{}",
                authenticated.aci, authenticated.device_id
            );
            let mut connection = state
                .redis
                .get_multiplexed_async_connection()
                .await
                .map_err(|_| Status::unavailable("PRESENCE_UNAVAILABLE"))?;
            redis::cmd("SET")
                .arg(key)
                .arg(presence.presence)
                .arg("EX")
                .arg(45)
                .query_async::<()>(&mut connection)
                .await
                .map_err(|_| Status::unavailable("PRESENCE_UNAVAILABLE"))?;
            Ok(None)
        }
        Some(client_frame::Body::Hello(_)) => {
            Err(Status::failed_precondition("HELLO_ALREADY_SENT"))
        }
        Some(client_frame::Body::FloorToken(token)) => {
            request_floor(state, authenticated, token).await.map(Some)
        }
        Some(client_frame::Body::FloorRelease(release)) => {
            release_floor(state, authenticated, release).await?;
            Ok(None)
        }
        None => Err(Status::invalid_argument("EMPTY_CLIENT_FRAME")),
    }
}

async fn request_floor(
    state: &AppState,
    authenticated: AuthenticatedDevice,
    token: wire::FloorToken,
) -> Result<ServerFrame, Status> {
    let channel_id = parse_uuid(&token.channel_id, "INVALID_CHANNEL_ID")?;
    if token.token.len() != 16 || token.sender_demux == 0 || token.membership_epoch == 0 {
        return Err(Status::invalid_argument("INVALID_FLOOR_TOKEN"));
    }
    let membership: Option<(i32, String, bool)> = sqlx::query_as(
        "SELECT c.membership_epoch, m.role, EXISTS(SELECT 1 FROM relay_leases l WHERE l.channel_id=c.channel_id AND l.aci=m.aci AND l.device_id=$3 AND l.sender_demux=$4 AND l.expires_at > now()) FROM channels c JOIN memberships m ON m.channel_id=c.channel_id WHERE c.channel_id=$1 AND m.aci=$2 AND m.left_epoch IS NULL",
    )
    .bind(channel_id)
    .bind(authenticated.aci)
    .bind(authenticated.device_id)
    .bind(i64::from(token.sender_demux))
    .fetch_optional(&state.pool)
    .await
    .map_err(internal)?;
    let (membership_epoch, role, relay_authorized) =
        membership.ok_or_else(|| Status::permission_denied("FORBIDDEN"))?;
    if !relay_authorized {
        return Err(Status::permission_denied("RELAY_LEASE_REQUIRED"));
    }
    if membership_epoch as u32 != token.membership_epoch {
        return Err(Status::failed_precondition("STALE_MEMBERSHIP_EPOCH"));
    }
    let allowed_priority = match role.as_str() {
        "talk" => 0,
        "barge" => 1,
        "dispatch" => 2,
        "emergency-target" => 3,
        _ => return Err(Status::permission_denied("TALK_NOT_ALLOWED")),
    };
    if token.priority_class > allowed_priority {
        return Err(Status::permission_denied("PRIORITY_NOT_ALLOWED"));
    }
    let granted_tot_ms = token.requested_tot_ms.clamp(1_000, 30_000);
    let owner = format!("{}:{}", authenticated.aci, authenticated.device_id);
    let key = format!("ptt:v1:floor:{channel_id}");
    let token_text = URL_SAFE_NO_PAD.encode(&token.token);
    let script = redis::Script::new(
        r#"
        if redis.call('EXISTS', KEYS[1]) == 1 then
          local current_owner = redis.call('HGET', KEYS[1], 'owner')
          local current_token = redis.call('HGET', KEYS[1], 'token')
          local current_priority = tonumber(redis.call('HGET', KEYS[1], 'priority'))
          if current_owner == ARGV[1] and current_token == ARGV[2] then
            return {2, tonumber(redis.call('HGET', KEYS[1], 'tot')), current_priority}
          end
          if tonumber(ARGV[3]) <= current_priority then return {0, 0, current_priority} end
        end
        redis.call('HSET', KEYS[1], 'owner', ARGV[1], 'token', ARGV[2], 'priority', ARGV[3], 'demux', ARGV[4], 'tot', ARGV[5])
        redis.call('PEXPIRE', KEYS[1], ARGV[6])
        return {1, tonumber(ARGV[5]), tonumber(ARGV[3])}
        "#,
    );
    let mut connection = state
        .redis
        .get_multiplexed_async_connection()
        .await
        .map_err(|_| Status::unavailable("FLOOR_UNAVAILABLE"))?;
    let (result, actual_tot, _): (i32, u32, i32) = script
        .key(key)
        .arg(&owner)
        .arg(&token_text)
        .arg(token.priority_class)
        .arg(token.sender_demux)
        .arg(granted_tot_ms)
        .arg(granted_tot_ms)
        .invoke_async(&mut connection)
        .await
        .map_err(|_| Status::unavailable("FLOOR_UNAVAILABLE"))?;
    let body = if result == 0 {
        server_frame::Body::FloorDeny(FloorSerializerDeny {
            token: token.token,
            channel_id: channel_id.as_bytes().to_vec(),
            reason: ErrorCode::FloorBusy as i32,
            retry_after_ms: 250,
        })
    } else {
        server_frame::Body::FloorGrant(FloorSerializerGrant {
            token: token.token,
            channel_id: channel_id.as_bytes().to_vec(),
            sender_demux: token.sender_demux,
            granted_tot_ms: actual_tot,
        })
    };
    Ok(ServerFrame { body: Some(body) })
}

async fn release_floor(
    state: &AppState,
    authenticated: AuthenticatedDevice,
    release: wire::FloorRelease,
) -> Result<(), Status> {
    let channel_id = parse_uuid(&release.channel_id, "INVALID_CHANNEL_ID")?;
    if release.token.len() != 16 || release.sender_demux == 0 {
        return Err(Status::invalid_argument("INVALID_FLOOR_RELEASE"));
    }
    let owner = format!("{}:{}", authenticated.aci, authenticated.device_id);
    let key = format!("ptt:v1:floor:{channel_id}");
    let token = URL_SAFE_NO_PAD.encode(release.token);
    let script = redis::Script::new(
        r#"
        if redis.call('HGET', KEYS[1], 'owner') == ARGV[1]
          and redis.call('HGET', KEYS[1], 'token') == ARGV[2]
          and tonumber(redis.call('HGET', KEYS[1], 'demux')) == tonumber(ARGV[3]) then
          redis.call('DEL', KEYS[1])
          return 1
        end
        return 0
        "#,
    );
    let mut connection = state
        .redis
        .get_multiplexed_async_connection()
        .await
        .map_err(|_| Status::unavailable("FLOOR_UNAVAILABLE"))?;
    let released: i32 = script
        .key(key)
        .arg(owner)
        .arg(token)
        .arg(release.sender_demux)
        .invoke_async(&mut connection)
        .await
        .map_err(|_| Status::unavailable("FLOOR_UNAVAILABLE"))?;
    if released == 1 {
        Ok(())
    } else {
        Err(Status::failed_precondition("FLOOR_NOT_HELD"))
    }
}

async fn register_push(
    pool: &PgPool,
    authenticated: AuthenticatedDevice,
    address: &DeviceAddress,
    provider: &str,
    token: &[u8],
) -> Result<(), Status> {
    if parse_uuid(&address.aci, "INVALID_ACI")? != authenticated.aci
        || address.device_id as i32 != authenticated.device_id
        || !matches!(
            provider,
            "fcm" | "apns" | "apns-ptt" | "apns-sandbox" | "apns-ptt-sandbox"
        )
        || !(16..=4096).contains(&token.len())
    {
        return Err(Status::invalid_argument("INVALID_PUSH_REGISTRATION"));
    }
    let mailbox = parse_uuid(&address.mailbox_id, "INVALID_MAILBOX_ID")?;
    let matches: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM devices WHERE aci = $1 AND device_id = $2 AND mailbox_id = $3 AND status = 'active')",
    )
    .bind(authenticated.aci)
    .bind(authenticated.device_id)
    .bind(mailbox)
    .fetch_one(pool)
    .await
    .map_err(internal)?;
    if !matches {
        return Err(Status::permission_denied("DEVICE_ADDRESS_MISMATCH"));
    }
    let owner: Option<(Uuid, i32)> = sqlx::query_as(
        "SELECT aci, device_id FROM push_registrations WHERE provider = $1 AND token = $2",
    )
    .bind(provider)
    .bind(token)
    .fetch_optional(pool)
    .await
    .map_err(internal)?;
    if owner.is_some_and(|owner| owner != (authenticated.aci, authenticated.device_id)) {
        return Err(Status::already_exists("PUSH_TOKEN_IN_USE"));
    }
    sqlx::query(
        "INSERT INTO push_registrations(aci, device_id, provider, token) VALUES ($1, $2, $3, $4) ON CONFLICT(aci, device_id, provider) DO UPDATE SET token = excluded.token, updated_at = now()",
    )
    .bind(authenticated.aci)
    .bind(authenticated.device_id)
    .bind(provider)
    .bind(token)
    .execute(pool)
    .await
    .map_err(internal)?;
    Ok(())
}

async fn enqueue_envelopes(
    pool: &PgPool,
    authenticated: AuthenticatedDevice,
    batch: DeviceEnvelopeBatch,
) -> Result<(), Status> {
    let message_id = parse_uuid(&batch.message_id, "INVALID_MESSAGE_ID")?;
    if batch.recipients.is_empty() || batch.recipients.len() > 128 {
        return Err(Status::invalid_argument("INVALID_RECIPIENTS"));
    }
    let expires_at = DateTime::from_timestamp_millis(batch.expires_at_ms as i64)
        .ok_or_else(|| Status::invalid_argument("INVALID_EXPIRATION"))?;
    let now = Utc::now();
    if expires_at <= now || expires_at > now + chrono::Duration::days(30) {
        return Err(Status::invalid_argument("INVALID_EXPIRATION"));
    }
    let mut unique = std::collections::HashSet::new();
    let mut decoded = Vec::with_capacity(batch.recipients.len());
    for recipient in batch.recipients {
        let target = recipient
            .address
            .ok_or_else(|| Status::invalid_argument("DEVICE_ADDRESS_REQUIRED"))?;
        let aci = parse_uuid(&target.aci, "INVALID_ACI")?;
        if !(1..=2).contains(&target.device_id)
            || recipient.envelope.is_empty()
            || recipient.envelope.len() > 65_536
            || !unique.insert((aci, target.device_id))
        {
            return Err(Status::invalid_argument("INVALID_RECIPIENTS"));
        }
        decoded.push((aci, target.device_id as i32, recipient.envelope));
    }
    let mut tx = pool.begin().await.map_err(internal)?;
    for (aci, device_id, envelope) in decoded {
        let mailbox_id: Option<Uuid> = sqlx::query_scalar(
            "SELECT d.mailbox_id FROM devices d JOIN accounts a ON a.aci = d.aci WHERE d.aci = $2 AND d.device_id = $3 AND d.status = 'active' AND a.disabled_at IS NULL AND ($1 = $2 OR EXISTS(SELECT 1 FROM memberships mine JOIN memberships theirs ON theirs.channel_id = mine.channel_id WHERE mine.aci = $1 AND theirs.aci = $2 AND mine.left_epoch IS NULL AND theirs.left_epoch IS NULL))",
        )
        .bind(authenticated.aci)
        .bind(aci)
        .bind(device_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(internal)?;
        let mailbox_id = mailbox_id.ok_or_else(|| Status::permission_denied("FORBIDDEN"))?;
        let inserted = sqlx::query(
            "INSERT INTO mailbox_items(item_id, message_id, mailbox_id, envelope, expires_at) VALUES ($1, $2, $3, $4, $5) ON CONFLICT(mailbox_id, message_id) DO NOTHING",
        )
        .bind(Uuid::new_v4())
        .bind(message_id)
        .bind(mailbox_id)
        .bind(envelope)
        .bind(expires_at)
        .execute(&mut *tx)
        .await
        .map_err(internal)?;
        if inserted.rows_affected() == 1 {
            sqlx::query(
                "INSERT INTO push_outbox(id, message_id, aci, device_id, provider) SELECT gen_random_uuid(), $1, $2, $3, provider FROM push_registrations WHERE aci = $2 AND device_id = $3 ON CONFLICT DO NOTHING",
            )
            .bind(message_id)
            .bind(aci)
            .bind(device_id)
            .execute(&mut *tx)
            .await
            .map_err(internal)?;
        }
    }
    tx.commit().await.map_err(internal)?;
    Ok(())
}

async fn take_mailbox_item(
    pool: &PgPool,
    authenticated: AuthenticatedDevice,
    address: &DeviceAddress,
) -> Result<Option<ServerFrame>, Status> {
    let mut tx = pool.begin().await.map_err(internal)?;
    let row: Option<(Uuid, Vec<u8>)> = sqlx::query_as(
        "UPDATE mailbox_items SET delivered_at = now() WHERE item_id = (SELECT i.item_id FROM mailbox_items i JOIN devices d ON d.mailbox_id = i.mailbox_id WHERE d.aci = $1 AND d.device_id = $2 AND d.status = 'active' AND i.delivered_at IS NULL AND i.expires_at > now() ORDER BY i.created_at FOR UPDATE SKIP LOCKED LIMIT 1) RETURNING item_id, envelope",
    )
    .bind(authenticated.aci)
    .bind(authenticated.device_id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(internal)?;
    tx.commit().await.map_err(internal)?;
    Ok(row.map(|(_, envelope)| ServerFrame {
        body: Some(server_frame::Body::Envelope(RecipientDevice {
            address: Some(address.clone()),
            envelope,
        })),
    }))
}

fn error_frame(status: &Status) -> ServerFrame {
    let code = match (status.code(), status.message()) {
        (tonic::Code::Unauthenticated, _) => ErrorCode::Unauthenticated,
        (tonic::Code::PermissionDenied, _) => ErrorCode::PermissionDenied,
        (tonic::Code::ResourceExhausted, _) => ErrorCode::RateLimited,
        (tonic::Code::FailedPrecondition, "UNSUPPORTED_VERSION") => ErrorCode::UnsupportedVersion,
        (tonic::Code::FailedPrecondition, "STALE_MEMBERSHIP_EPOCH") => {
            ErrorCode::StaleMembershipEpoch
        }
        (tonic::Code::FailedPrecondition, "FLOOR_NOT_HELD") => ErrorCode::FloorTimeout,
        _ => ErrorCode::Internal,
    };
    ServerFrame {
        body: Some(server_frame::Body::Error(ApiError {
            code: code as i32,
            safe_message: status.message().to_owned(),
            retry_after_ms: 0,
        })),
    }
}

fn parse_uuid(bytes: &[u8], message: &'static str) -> Result<Uuid, Status> {
    Uuid::from_slice(bytes).map_err(|_| Status::invalid_argument(message))
}

fn internal(error: impl std::fmt::Display) -> Status {
    tracing::error!(error = %error, "gRPC database operation failed");
    Status::internal("INTERNAL")
}

fn metadata_device_token<T>(request: &Request<T>) -> Result<String, Status> {
    request
        .metadata()
        .get("authorization")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
        .ok_or_else(|| Status::unauthenticated("UNAUTHENTICATED"))
}

pub(crate) async fn authenticate_metadata<T>(
    pool: &PgPool,
    request: &Request<T>,
) -> Result<AuthenticatedDevice, Status> {
    let token = metadata_device_token(request)?;
    let token_hash = hash_secret(&token);
    sqlx::query_as::<_, (Uuid, i32, bool)>(
        "SELECT a.aci, d.device_id, a.is_admin FROM accounts a JOIN devices d ON d.aci = a.aci WHERE d.access_token_sha256 = $1 AND d.status = 'active' AND a.disabled_at IS NULL",
    )
    .bind(token_hash.as_slice())
    .fetch_optional(pool)
    .await
    .map_err(internal)?
    .map(|(aci, device_id, is_admin)| AuthenticatedDevice {
        aci,
        device_id,
        is_admin,
        access_token_sha256: token_hash,
    })
    .ok_or_else(|| Status::unauthenticated("UNAUTHENTICATED"))
}

#[tonic::async_trait]
impl PreKeyService for GrpcPreKeyService {
    async fn upload(
        &self,
        request: Request<UploadPreKeysRequest>,
    ) -> Result<Response<Empty>, Status> {
        let authenticated = authenticate_metadata(&self.state.pool, &request).await?;
        let payload = request.into_inner();
        let address = payload
            .device
            .as_ref()
            .ok_or_else(|| Status::invalid_argument("DEVICE_ADDRESS_REQUIRED"))?;
        if parse_uuid(&address.aci, "INVALID_ACI")? != authenticated.aci
            || address.device_id as i32 != authenticated.device_id
            || payload.identity_key.is_empty()
            || payload.signed_prekey.is_empty()
            || payload.one_time_prekeys.len() > 200
            || payload.kyber_prekeys.len() > 200
        {
            return Err(Status::invalid_argument("INVALID_PREKEY_BUNDLE"));
        }
        let opaque_bundle = payload.encode_to_vec();
        if opaque_bundle.len() > 65_536 {
            return Err(Status::invalid_argument("INVALID_PREKEY_BUNDLE"));
        }
        let mut tx = self.state.pool.begin().await.map_err(internal)?;
        sqlx::query(
            "INSERT INTO prekey_bundles(aci, device_id, opaque_bundle) VALUES ($1, $2, $3) ON CONFLICT(aci,device_id) DO UPDATE SET opaque_bundle=excluded.opaque_bundle, updated_at=now()",
        )
        .bind(authenticated.aci)
        .bind(authenticated.device_id)
        .bind(opaque_bundle)
        .execute(&mut *tx)
        .await
        .map_err(internal)?;
        for (kind, keys) in [
            ("x25519", payload.one_time_prekeys),
            ("kyber", payload.kyber_prekeys),
        ] {
            for key in keys {
                if !(16..=4096).contains(&key.len()) {
                    return Err(Status::invalid_argument("INVALID_PREKEY"));
                }
                sqlx::query("INSERT INTO one_time_prekeys(aci,device_id,kind,public_key) VALUES($1,$2,$3,$4)")
                    .bind(authenticated.aci)
                    .bind(authenticated.device_id)
                    .bind(kind)
                    .bind(key)
                    .execute(&mut *tx)
                    .await
                    .map_err(internal)?;
            }
        }
        tx.commit().await.map_err(internal)?;
        Ok(Response::new(Empty {}))
    }

    async fn fetch_batch(
        &self,
        request: Request<FetchPreKeysRequest>,
    ) -> Result<Response<FetchPreKeysResponse>, Status> {
        let authenticated = authenticate_metadata(&self.state.pool, &request).await?;
        let payload = request.into_inner();
        if payload.devices.is_empty() || payload.devices.len() > MAX_PREKEY_BATCH_DEVICES {
            return Err(Status::invalid_argument("INVALID_PREKEY_BATCH"));
        }
        let mut tx = self.state.pool.begin().await.map_err(internal)?;
        let mut bundles = Vec::new();
        for address in payload.devices {
            let aci = parse_uuid(&address.aci, "INVALID_ACI")?;
            let authorized: bool = sqlx::query_scalar(
                "SELECT $1 = $2 OR EXISTS(SELECT 1 FROM memberships mine JOIN memberships theirs ON theirs.channel_id=mine.channel_id WHERE mine.aci=$1 AND theirs.aci=$2 AND mine.left_epoch IS NULL AND theirs.left_epoch IS NULL)",
            )
            .bind(authenticated.aci)
            .bind(aci)
            .fetch_one(&mut *tx)
            .await
            .map_err(internal)?;
            if !authorized {
                return Err(Status::permission_denied("FORBIDDEN"));
            }
            let opaque: Option<Vec<u8>> = sqlx::query_scalar(
                "SELECT p.opaque_bundle FROM prekey_bundles p JOIN devices d ON d.aci=p.aci AND d.device_id=p.device_id WHERE p.aci=$1 AND p.device_id=$2 AND d.status='active'",
            )
            .bind(aci)
            .bind(address.device_id as i32)
            .fetch_optional(&mut *tx)
            .await
            .map_err(internal)?;
            let Some(opaque) = opaque else { continue };
            let uploaded = UploadPreKeysRequest::decode(opaque.as_slice())
                .map_err(|_| Status::internal("INVALID_STORED_PREKEY"))?;
            let one_time_prekey =
                consume_prekey(&mut tx, aci, address.device_id as i32, "x25519").await?;
            let kyber_prekey =
                consume_prekey(&mut tx, aci, address.device_id as i32, "kyber").await?;
            bundles.push(PreKeyBundle {
                device: Some(address),
                identity_key: uploaded.identity_key,
                signed_prekey: uploaded.signed_prekey,
                one_time_prekey: one_time_prekey.unwrap_or_default(),
                kyber_prekey: kyber_prekey.unwrap_or_default(),
            });
        }
        tx.commit().await.map_err(internal)?;
        Ok(Response::new(FetchPreKeysResponse { bundles }))
    }
}

async fn consume_prekey(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    aci: Uuid,
    device_id: i32,
    kind: &str,
) -> Result<Option<Vec<u8>>, Status> {
    sqlx::query_scalar(
        "UPDATE one_time_prekeys SET consumed_at=now() WHERE id=(SELECT id FROM one_time_prekeys WHERE aci=$1 AND device_id=$2 AND kind=$3 AND consumed_at IS NULL ORDER BY id FOR UPDATE SKIP LOCKED LIMIT 1) RETURNING public_key",
    )
    .bind(aci)
    .bind(device_id)
    .bind(kind)
    .fetch_optional(&mut **tx)
    .await
    .map_err(internal)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uuid_fields_require_exactly_sixteen_bytes() {
        let id = Uuid::new_v4();
        assert_eq!(parse_uuid(id.as_bytes(), "bad").unwrap(), id);
        assert!(parse_uuid(&[0; 15], "bad").is_err());
    }

    #[test]
    fn explicit_errors_never_grant_fallback_behavior() {
        let frame = error_frame(&Status::permission_denied("FORBIDDEN"));
        let Some(server_frame::Body::Error(error)) = frame.body else {
            panic!("error frame")
        };
        assert_eq!(error.code, ErrorCode::PermissionDenied as i32);
        assert_eq!(error.retry_after_ms, 0);

        let frame = error_frame(&Status::failed_precondition("STALE_MEMBERSHIP_EPOCH"));
        let Some(server_frame::Body::Error(error)) = frame.body else {
            panic!("error frame")
        };
        assert_eq!(error.code, ErrorCode::StaleMembershipEpoch as i32);
    }
}
