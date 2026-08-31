mod grpc;
mod media_fallback;
mod object_store;
mod push;

use anyhow::{Context, Result};
use axum::{
    body::Bytes,
    extract::{DefaultBodyLimit, Path, Query, State},
    http::{header, HeaderMap, HeaderName, HeaderValue, StatusCode},
    response::{Html, IntoResponse},
    routing::{get, post, put},
    Json, Router,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use chrono::{DateTime, Duration, Utc};
use grpc::{
    wire::{
        control_service_server::ControlServiceServer, pre_key_service_server::PreKeyServiceServer,
    },
    GrpcControlService, GrpcPreKeyService,
};
use hmac::{Hmac, Mac};
use lettre::{
    message::Mailbox,
    transport::smtp::{
        authentication::Credentials,
        client::{Tls, TlsParameters},
    },
    AsyncSmtpTransport, AsyncTransport, Message, Tokio1Executor,
};
use media_fallback::{
    media_wire::media_fallback_service_server::MediaFallbackServiceServer, websocket_tunnel,
    MediaFallback, MediaHub,
};
use object_store::{ObjectStore, ObjectStoreError};
use ptt_server_core::{
    hash_secret, issue_relay_ticket, secret_matches, IssuedSecret, MagicLinkPurpose,
    MAGIC_LINK_TTL_MINUTES, MAX_PREKEY_BATCH_DEVICES,
};
use push::{PushDispatcher, PushResult};
use rand::Rng;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use sqlx::{postgres::PgPoolOptions, PgPool, Postgres, Transaction};
use std::{env, net::SocketAddr, sync::Arc};
use tower_http::{
    catch_panic::CatchPanicLayer,
    request_id::{MakeRequestUuid, PropagateRequestIdLayer, SetRequestIdLayer},
    trace::TraceLayer,
};
use tracing::{info, warn};
use uuid::Uuid;

const MAX_MAILBOX_BATCH_RECIPIENTS: usize = 128;
const MAX_MAILBOX_ENVELOPE_BYTES: usize = 65_536;
const MAX_MAILBOX_POLL_ITEMS: i64 = 256;
const MAX_MAILBOX_TTL_DAYS: i64 = 30;
const MAX_HISTORY_CIPHERTEXT_BYTES: usize = 16 * 1024 * 1024;
const MAX_HISTORY_LIST_ITEMS: i64 = 200;
const MAX_HISTORY_DURATION_MS: u32 = 30_000;
const MAX_CHAT_ATTACHMENT_BYTES: usize = 25 * 1024 * 1024 + 64;
const CHAT_ATTACHMENT_PART_BYTES: usize = 1024 * 1024;
const MAX_CHAT_ENVELOPE_BYTES: usize = 131_072;

#[derive(Clone)]
struct AppState {
    pool: PgPool,
    public_base_url: Arc<str>,
    bootstrap_token_sha256: [u8; 32],
    relay_signing_key: Arc<[u8]>,
    relay_public_address: Arc<str>,
    redis: redis::Client,
    object_store: ObjectStore,
    push: PushDispatcher,
    media_hub: MediaHub,
}

#[derive(Clone)]
struct MetricsState {
    pool: PgPool,
    access_token_sha256: [u8; 32],
}

#[derive(Debug, PartialEq)]
struct MetricsSnapshot {
    accounts: i64,
    active_devices: i64,
    channels: i64,
    active_relay_leases: i64,
    pending_email: i64,
    pending_recoveries: i64,
    pending_push: i64,
    failed_push: i64,
    history_objects: i64,
    history_ciphertext_bytes: i64,
    database_connections: u32,
    database_idle_connections: usize,
}

#[derive(Clone)]
struct SmtpSettings {
    host: String,
    port: u16,
    username: String,
    password: String,
    from: Mailbox,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct HealthResponse {
    status: &'static str,
    protocol_major: u32,
    protocol_minor: u32,
    minimum_client_major: u32,
    minimum_client_minor: u32,
    capabilities: &'static [&'static str],
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct BootstrapRequest {
    email: String,
    bootstrap_token: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct BootstrapResponse {
    invitation_code: String,
    expires_at: chrono::DateTime<Utc>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct MagicLinkRequest {
    email: String,
    invitation_code: String,
}

#[derive(Debug, Serialize)]
struct AcceptedResponse {
    accepted: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ConsumeMagicLinkRequest {
    token: String,
    device_name: String,
    identity_key: String,
    resume_secret: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct EnrolledDeviceResponse {
    aci: Uuid,
    device_id: i32,
    mailbox_id: Uuid,
    access_token: String,
}

#[derive(Debug, Deserialize)]
struct CreateInvitationRequest {
    email: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct InvitationResponse {
    invitation_code: String,
    expires_at: chrono::DateTime<Utc>,
}

#[derive(Debug, Serialize, sqlx::FromRow)]
#[serde(rename_all = "camelCase")]
struct MemberRow {
    aci: Uuid,
    email: String,
    is_admin: bool,
    active_devices: i64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct AdminSummary {
    accounts: i64,
    active_devices: i64,
    channels: i64,
    pending_email: i64,
    pending_recoveries: i64,
}

#[derive(Debug, Serialize, sqlx::FromRow)]
#[serde(rename_all = "camelCase")]
struct AdminDeviceRow {
    aci: Uuid,
    email: String,
    device_id: i32,
    display_name: String,
    status: String,
    linked_at: DateTime<Utc>,
    revoked_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct AdminRevokeDeviceRequest {
    aci: Uuid,
    device_id: i32,
}

#[derive(Debug, Serialize, sqlx::FromRow)]
#[serde(rename_all = "camelCase")]
struct AdminAuditRow {
    event_id: i64,
    action: String,
    subject_hash: Option<String>,
    detail: serde_json::Value,
    created_at: DateTime<Utc>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct AdminOperations {
    active_relay_leases: i64,
    pending_push: i64,
    failed_push: i64,
    history_objects: i64,
    fcm_configured: bool,
    apns_configured: bool,
    backup_configured: bool,
    backup_schedule: String,
    configuration_fingerprint: String,
}

#[derive(Debug, Deserialize)]
struct AdminAuditQuery {
    limit: Option<i64>,
}

#[derive(Debug, Clone, Copy)]
struct AuthenticatedDevice {
    aci: Uuid,
    device_id: i32,
    is_admin: bool,
    access_token_sha256: [u8; 32],
}

#[derive(Debug, Serialize, sqlx::FromRow)]
#[serde(rename_all = "camelCase")]
struct DeviceRow {
    device_id: i32,
    mailbox_id: Uuid,
    display_name: String,
    status: String,
    linked_at: chrono::DateTime<Utc>,
    revoked_at: Option<chrono::DateTime<Utc>>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RevokeDeviceRequest {
    device_id: i32,
}

#[derive(Debug, Deserialize)]
struct DeleteAccountRequest {
    confirmation: String,
}

#[derive(Debug, Deserialize)]
struct RecoveryRequest {
    email: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ConsumeRecoveryRequest {
    token: String,
    device_name: String,
    identity_key: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct RecoveryClaimResponse {
    request_id: Uuid,
    claim_token: String,
    status: &'static str,
    expires_at: DateTime<Utc>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RecoveryStatusRequest {
    request_id: Uuid,
    claim_token: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct RecoveryStatusResponse {
    status: String,
    aci: Option<Uuid>,
    device_id: Option<i32>,
    mailbox_id: Option<Uuid>,
}

#[derive(Debug, Serialize, sqlx::FromRow)]
#[serde(rename_all = "camelCase")]
struct AdminRecoveryRow {
    request_id: Uuid,
    email: String,
    device_name: String,
    status: String,
    expires_at: DateTime<Utc>,
    created_at: DateTime<Utc>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RecoveryDecisionRequest {
    request_id: Uuid,
    approve: bool,
}

type PendingRecovery = (Uuid, Uuid, String, Vec<u8>, Vec<u8>);

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct UploadPreKeysRequest {
    opaque_bundle: String,
    one_time_prekeys: Vec<OneTimePreKeyInput>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct OneTimePreKeyInput {
    kind: String,
    key_id: i32,
    public_key: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct FetchPreKeysRequest {
    devices: Vec<DeviceReference>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct DeviceReference {
    aci: Uuid,
    device_id: i32,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct PreKeyBundleResponse {
    aci: Uuid,
    device_id: i32,
    opaque_bundle: String,
    one_time_prekeys: Vec<OneTimePreKeyResponse>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct OneTimePreKeyResponse {
    kind: String,
    key_id: i32,
    public_key: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct DeviceLinkStartResponse {
    request_id: Uuid,
    link_code: String,
    expires_at: chrono::DateTime<Utc>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct DeviceLinkClaimRequest {
    request_id: Uuid,
    link_code: String,
    device_name: String,
    identity_key: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct DeviceLinkClaimResponse {
    aci: Uuid,
    device_id: i32,
    mailbox_id: Uuid,
    claim_token: String,
    status: &'static str,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct DeviceLinkApproveRequest {
    request_id: Uuid,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct DeviceLinkStatusRequest {
    claim_token: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct DeviceLinkStatusResponse {
    aci: Uuid,
    device_id: i32,
    mailbox_id: Uuid,
    status: String,
}

#[derive(Debug, Serialize, sqlx::FromRow)]
#[serde(rename_all = "camelCase")]
struct AdminChannelRow {
    channel_id: Uuid,
    display_name: String,
    kind: String,
    membership_epoch: i32,
    retention_days: i32,
    active_members: i64,
}

#[derive(Debug, Serialize, sqlx::FromRow)]
#[serde(rename_all = "camelCase")]
struct AdminChannelMemberRow {
    channel_id: Uuid,
    aci: Uuid,
    email: String,
    role: String,
    joined_epoch: i32,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct AdminChannelMembersQuery {
    channel_id: Uuid,
}

#[derive(Debug, Serialize, sqlx::FromRow)]
#[serde(rename_all = "camelCase")]
struct DeviceChannelRow {
    channel_id: Uuid,
    display_name: String,
    kind: String,
    distribution_id: Uuid,
    membership_epoch: i32,
    retention_days: i32,
    role: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ChannelDeviceResponse {
    aci: Uuid,
    device_id: i32,
    mailbox_id: Uuid,
    identity_key: String,
    role: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CreateChannelRequest {
    display_name: String,
    kind: String,
    retention_days: i32,
    members: Vec<ChannelMemberInput>,
}

#[derive(Debug, Deserialize)]
struct ChannelMemberInput {
    aci: Uuid,
    role: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct UpdateMembershipRequest {
    channel_id: Uuid,
    aci: Uuid,
    role: Option<String>,
    remove: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct UpdateChannelConfigRequest {
    channel_id: Uuid,
    display_name: String,
    retention_days: i32,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RelayCredentialRequest {
    channel_id: Uuid,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct RelayCredentialResponse {
    relay_address: String,
    ticket: String,
    demux_token: String,
    sender_demux: u32,
    expires_at: chrono::DateTime<Utc>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct FloorRequestBody {
    channel_id: Uuid,
    request_token: String,
    sender_demux: u32,
    membership_epoch: i32,
    requested_tot_ms: u32,
    sos: bool,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct FloorResponse {
    granted: bool,
    request_token: String,
    granted_tot_ms: u32,
    priority: i32,
    reason: Option<&'static str>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct FloorReleaseBody {
    channel_id: Uuid,
    request_token: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct MailboxEnvelopeBatchRequest {
    message_id: Uuid,
    recipients: Vec<MailboxRecipientInput>,
    expires_at: DateTime<Utc>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct MailboxRecipientInput {
    aci: Uuid,
    device_id: i32,
    envelope: String,
}

#[derive(Debug)]
struct DecodedMailboxRecipient {
    aci: Uuid,
    device_id: i32,
    envelope: Vec<u8>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct MailboxEnqueueResponse {
    accepted_recipients: u64,
}

#[derive(Debug, Deserialize)]
struct MailboxPollQuery {
    limit: Option<i64>,
}

#[derive(Debug, sqlx::FromRow)]
struct MailboxItemRow {
    item_id: Uuid,
    message_id: Uuid,
    envelope: Vec<u8>,
    expires_at: DateTime<Utc>,
    created_at: DateTime<Utc>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct MailboxItemResponse {
    item_id: Uuid,
    message_id: Uuid,
    envelope: String,
    expires_at: DateTime<Utc>,
    created_at: DateTime<Utc>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct MailboxAckRequest {
    item_ids: Vec<Uuid>,
}

#[derive(Debug, Serialize)]
struct MailboxAckResponse {
    acknowledged: u64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ChatBatchRequest {
    message_id: Uuid,
    channel_id: Uuid,
    membership_epoch: i32,
    recipients: Vec<MailboxRecipientInput>,
    expires_at: DateTime<Utc>,
}

#[derive(Debug, Deserialize)]
struct ChatPollQuery {
    limit: Option<i64>,
}

#[derive(Debug, sqlx::FromRow)]
struct ChatItemRow {
    item_id: Uuid,
    message_id: Uuid,
    channel_id: Uuid,
    membership_epoch: i32,
    envelope: Vec<u8>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ChatItemResponse {
    item_id: Uuid,
    message_id: Uuid,
    channel_id: Uuid,
    membership_epoch: i32,
    envelope: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ChatAttachmentQuery {
    channel_id: Uuid,
    membership_epoch: i32,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ChatAttachmentResponse {
    attachment_id: Uuid,
    ciphertext_bytes: i64,
    ciphertext_sha256: String,
    expires_at: DateTime<Utc>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ChatAttachmentUploadRequest {
    channel_id: Uuid,
    membership_epoch: i32,
    ciphertext_bytes: i64,
    ciphertext_sha256: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ChatAttachmentUploadPartResponse {
    part_number: i32,
    ciphertext_bytes: i32,
    ciphertext_sha256: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ChatAttachmentUploadResponse {
    state: &'static str,
    attachment_id: Uuid,
    #[serde(skip_serializing_if = "Option::is_none")]
    upload_id: Option<Uuid>,
    ciphertext_bytes: i64,
    ciphertext_sha256: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    part_size: Option<usize>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    uploaded_parts: Vec<ChatAttachmentUploadPartResponse>,
    expires_at: DateTime<Utc>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ChatAttachmentPartStoredResponse {
    upload_id: Uuid,
    part_number: i32,
    ciphertext_bytes: i32,
    ciphertext_sha256: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ChatAttachmentCancelResponse {
    cancelled: bool,
    attachment_id: Uuid,
    upload_id: Uuid,
}

#[derive(Debug, sqlx::FromRow)]
struct ChatAttachmentUploadRow {
    upload_id: Uuid,
    attachment_id: Uuid,
    channel_id: Uuid,
    membership_epoch: i32,
    uploader_aci: Uuid,
    uploader_device_id: i32,
    storage_key: String,
    ciphertext_bytes: i64,
    ciphertext_sha256: Vec<u8>,
    part_size: i32,
    expires_at: DateTime<Utc>,
}

#[derive(Debug, sqlx::FromRow)]
struct ChatAttachmentUploadPartRow {
    part_number: i32,
    storage_key: String,
    ciphertext_bytes: i32,
    ciphertext_sha256: Vec<u8>,
}

#[derive(Debug, Deserialize)]
struct PushRegistrationRequest {
    provider: String,
    token: String,
}

#[derive(Debug, Deserialize)]
struct PushRegistrationRemoveRequest {
    provider: String,
}

#[derive(Debug, Deserialize)]
struct PresenceRequest {
    mode: String,
}

#[derive(Debug, sqlx::FromRow)]
struct PushOutboxRow {
    id: Uuid,
    message_id: Uuid,
    aci: Uuid,
    device_id: i32,
    provider: String,
    token: Vec<u8>,
    attempts: i32,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct HistoryUploadRequest {
    talk_id: Uuid,
    channel_id: Uuid,
    membership_epoch: i32,
    media_kid: String,
    started_at: DateTime<Utc>,
    duration_ms: u32,
    ciphertext: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct HistoryListQuery {
    channel_id: Uuid,
    limit: Option<i64>,
}

#[derive(Debug, sqlx::FromRow)]
struct HistoryObjectRow {
    object_id: Uuid,
    talk_id: Uuid,
    channel_id: Uuid,
    membership_epoch: i32,
    media_kid: String,
    started_at: DateTime<Utc>,
    duration_ms: i32,
    expires_at: DateTime<Utc>,
    storage_key: String,
    ciphertext_bytes: i64,
    ciphertext_sha256: Option<Vec<u8>>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct HistoryMetadataResponse {
    object_id: Uuid,
    talk_id: Uuid,
    channel_id: Uuid,
    membership_epoch: i32,
    media_kid: String,
    started_at: DateTime<Utc>,
    duration_ms: i32,
    expires_at: DateTime<Utc>,
    ciphertext_bytes: i64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct HistoryDownloadResponse {
    metadata: HistoryMetadataResponse,
    ciphertext: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ErrorBody {
    code: &'static str,
    message: &'static str,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .json()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();

    let database_url = env::var("DATABASE_URL").context("DATABASE_URL is required")?;
    let public_base_url =
        env::var("PTT_PUBLIC_BASE_URL").context("PTT_PUBLIC_BASE_URL is required")?;
    let bootstrap_token =
        env::var("PTT_BOOTSTRAP_TOKEN").context("PTT_BOOTSTRAP_TOKEN is required")?;
    if bootstrap_token.len() < 32 {
        anyhow::bail!("PTT_BOOTSTRAP_TOKEN must contain at least 32 characters");
    }
    let relay_signing_key =
        env::var("PTT_RELAY_SHARED_SECRET").context("PTT_RELAY_SHARED_SECRET is required")?;
    if relay_signing_key.len() < 32 {
        anyhow::bail!("PTT_RELAY_SHARED_SECRET must contain at least 32 characters");
    }
    let relay_public_address =
        env::var("PTT_RELAY_PUBLIC_ADDRESS").context("PTT_RELAY_PUBLIC_ADDRESS is required")?;
    let redis_url = env::var("PTT_REDIS_URL").context("PTT_REDIS_URL is required")?;
    let redis = redis::Client::open(redis_url).context("parse PTT_REDIS_URL")?;
    let object_store = ObjectStore::new(
        &env::var("PTT_OBJECT_STORE_ENDPOINT").context("PTT_OBJECT_STORE_ENDPOINT is required")?,
        env::var("PTT_OBJECT_STORE_BUCKET").context("PTT_OBJECT_STORE_BUCKET is required")?,
        env::var("PTT_OBJECT_STORE_ACCESS_KEY")
            .context("PTT_OBJECT_STORE_ACCESS_KEY is required")?,
        env::var("PTT_OBJECT_STORE_SECRET_KEY")
            .context("PTT_OBJECT_STORE_SECRET_KEY is required")?,
    )
    .context("configure object store")?;
    let push = PushDispatcher::from_env().context("configure push providers")?;
    let metrics = match (
        env::var("PTT_METRICS_BIND").ok(),
        env::var("PTT_METRICS_TOKEN").ok(),
    ) {
        (Some(bind), Some(token)) if token.len() >= 32 => Some((
            bind.parse::<SocketAddr>()
                .context("parse PTT_METRICS_BIND")?,
            hash_secret(&token),
        )),
        (None, None) => None,
        (Some(_), Some(_)) => {
            anyhow::bail!("PTT_METRICS_TOKEN must contain at least 32 characters")
        }
        _ => anyhow::bail!("PTT_METRICS_BIND and PTT_METRICS_TOKEN must be configured together"),
    };

    let pool = PgPoolOptions::new()
        .max_connections(20)
        .connect(&database_url)
        .await
        .context("connect to postgres")?;
    sqlx::migrate!("./migrations")
        .run(&pool)
        .await
        .context("run migrations")?;

    let state = AppState {
        pool,
        public_base_url: public_base_url.into(),
        bootstrap_token_sha256: hash_secret(&bootstrap_token),
        relay_signing_key: relay_signing_key.into_bytes().into(),
        relay_public_address: relay_public_address.into(),
        redis,
        object_store,
        push,
        media_hub: MediaHub::default(),
    };
    if let Some(smtp) = smtp_settings()? {
        tokio::spawn(email_worker(state.pool.clone(), smtp));
    } else {
        warn!("SMTP is not configured; enrollment email remains queued");
    }
    tokio::spawn(maintenance_worker(state.clone()));
    tokio::spawn(push_worker(state.clone()));
    let metrics_task = if let Some((metrics_bind, access_token_sha256)) = metrics {
        let metrics_listener = tokio::net::TcpListener::bind(metrics_bind).await?;
        let metrics_state = MetricsState {
            pool: state.pool.clone(),
            access_token_sha256,
        };
        info!(%metrics_bind, "authenticated metrics service ready");
        Some(tokio::spawn(async move {
            axum::serve(
                metrics_listener,
                Router::new()
                    .route("/metrics", get(metrics_endpoint))
                    .with_state(metrics_state),
            )
            .await
        }))
    } else {
        None
    };
    let grpc_state = state.clone();
    let app = app(state);
    let bind: SocketAddr = env::var("PTT_CONTROL_BIND")
        .unwrap_or_else(|_| "0.0.0.0:8080".to_owned())
        .parse()
        .context("parse PTT_CONTROL_BIND")?;
    let listener = tokio::net::TcpListener::bind(bind).await?;
    let grpc_bind: SocketAddr = env::var("PTT_GRPC_BIND")
        .unwrap_or_else(|_| "0.0.0.0:50051".to_owned())
        .parse()
        .context("parse PTT_GRPC_BIND")?;
    let media_fallback = MediaFallback::new(
        grpc_state.media_hub.clone(),
        grpc_state.pool.clone(),
        grpc_state.redis.clone(),
    );
    let grpc_task = tokio::spawn(async move {
        tonic::transport::Server::builder()
            .add_service(ControlServiceServer::new(GrpcControlService::new(
                grpc_state.clone(),
            )))
            .add_service(PreKeyServiceServer::new(GrpcPreKeyService::new(grpc_state)))
            .add_service(MediaFallbackServiceServer::new(media_fallback))
            .serve(grpc_bind)
            .await
    });
    info!(%bind, "control service ready");
    let result = axum::serve(listener, app)
        .with_graceful_shutdown(shutdown())
        .await;
    grpc_task.abort();
    if let Some(task) = metrics_task {
        task.abort();
    }
    result?;
    Ok(())
}

async fn metrics_endpoint(
    State(state): State<MetricsState>,
    headers: HeaderMap,
) -> impl IntoResponse {
    let supplied = headers
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .filter(|value| !value.is_empty());
    if !supplied
        .map(|token| secret_matches(&state.access_token_sha256, token))
        .unwrap_or(false)
    {
        return StatusCode::UNAUTHORIZED.into_response();
    }

    match collect_metrics(&state.pool).await {
        Ok(snapshot) => (
            StatusCode::OK,
            [(
                header::CONTENT_TYPE,
                "text/plain; version=0.0.4; charset=utf-8",
            )],
            format_metrics(&snapshot),
        )
            .into_response(),
        Err(error) => {
            tracing::error!(error = %error, "metrics query failed");
            StatusCode::SERVICE_UNAVAILABLE.into_response()
        }
    }
}

async fn collect_metrics(pool: &PgPool) -> Result<MetricsSnapshot, sqlx::Error> {
    let (
        accounts,
        active_devices,
        channels,
        active_relay_leases,
        pending_email,
        pending_recoveries,
        pending_push,
        failed_push,
        history_objects,
        history_ciphertext_bytes,
    ): (i64, i64, i64, i64, i64, i64, i64, i64, i64, i64) = sqlx::query_as(
        r#"SELECT
          (SELECT count(*) FROM accounts WHERE disabled_at IS NULL),
          (SELECT count(*) FROM devices WHERE status='active'),
          (SELECT count(*) FROM channels),
          (SELECT count(*) FROM relay_leases WHERE expires_at > now()),
          (SELECT count(*) FROM email_outbox WHERE sent_at IS NULL),
          (SELECT count(*) FROM recovery_requests WHERE status='pending_admin' AND expires_at > now()),
          (SELECT count(*) FROM push_outbox WHERE sent_at IS NULL),
          (SELECT count(*) FROM push_outbox WHERE sent_at IS NULL AND attempts > 0),
          (SELECT count(*) FROM history_objects WHERE expires_at > now()),
          (SELECT COALESCE(sum(ciphertext_bytes), 0)::bigint FROM history_objects WHERE expires_at > now())"#,
    )
    .fetch_one(pool)
    .await?;
    Ok(MetricsSnapshot {
        accounts,
        active_devices,
        channels,
        active_relay_leases,
        pending_email,
        pending_recoveries,
        pending_push,
        failed_push,
        history_objects,
        history_ciphertext_bytes,
        database_connections: pool.size(),
        database_idle_connections: pool.num_idle(),
    })
}

fn format_metrics(value: &MetricsSnapshot) -> String {
    let fields = [
        ("ptt_accounts", value.accounts),
        ("ptt_active_devices", value.active_devices),
        ("ptt_channels", value.channels),
        ("ptt_active_relay_leases", value.active_relay_leases),
        ("ptt_pending_email", value.pending_email),
        ("ptt_pending_recoveries", value.pending_recoveries),
        ("ptt_pending_push", value.pending_push),
        ("ptt_failed_push", value.failed_push),
        ("ptt_history_objects", value.history_objects),
        (
            "ptt_history_ciphertext_bytes",
            value.history_ciphertext_bytes,
        ),
        (
            "ptt_database_connections",
            i64::from(value.database_connections),
        ),
        (
            "ptt_database_idle_connections",
            value.database_idle_connections as i64,
        ),
    ];
    let mut output = String::from(
        "# PTT Talk exports aggregate operational gauges only; no account, device, channel, or email labels are emitted.\n",
    );
    for (name, metric) in fields {
        output.push_str("# TYPE ");
        output.push_str(name);
        output.push_str(" gauge\n");
        output.push_str(name);
        output.push(' ');
        output.push_str(&metric.to_string());
        output.push('\n');
    }
    output
}

fn smtp_settings() -> Result<Option<SmtpSettings>> {
    let Ok(host) = env::var("PTT_SMTP_HOST") else {
        return Ok(None);
    };
    let port = env::var("PTT_SMTP_PORT")
        .unwrap_or_else(|_| "587".to_owned())
        .parse()
        .context("parse PTT_SMTP_PORT")?;
    let username = env::var("PTT_SMTP_USERNAME").context("PTT_SMTP_USERNAME is required")?;
    let password = env::var("PTT_SMTP_PASSWORD").context("PTT_SMTP_PASSWORD is required")?;
    let from = env::var("PTT_SMTP_FROM")
        .context("PTT_SMTP_FROM is required")?
        .parse()
        .context("parse PTT_SMTP_FROM")?;
    Ok(Some(SmtpSettings {
        host,
        port,
        username,
        password,
        from,
    }))
}

async fn email_worker(pool: PgPool, settings: SmtpSettings) {
    let tls = match TlsParameters::new(settings.host.clone()) {
        Ok(value) => value,
        Err(error) => {
            tracing::error!(error = %error, "invalid SMTP TLS configuration");
            return;
        }
    };
    let transport = AsyncSmtpTransport::<Tokio1Executor>::builder_dangerous(&settings.host)
        .port(settings.port)
        .tls(Tls::Required(tls))
        .credentials(Credentials::new(settings.username, settings.password))
        .build();
    let mut interval = tokio::time::interval(std::time::Duration::from_secs(5));
    loop {
        interval.tick().await;
        if let Err(error) = deliver_one_email(&pool, &transport, &settings.from).await {
            tracing::error!(error = %error, "email delivery cycle failed");
        }
    }
}

async fn deliver_one_email(
    pool: &PgPool,
    transport: &AsyncSmtpTransport<Tokio1Executor>,
    from: &Mailbox,
) -> Result<()> {
    let mut tx = pool.begin().await?;
    sqlx::query(
        "UPDATE email_outbox SET sent_at = now(), last_error = 'expired before delivery', payload = '{}'::jsonb WHERE sent_at IS NULL AND created_at <= now() - interval '10 minutes'",
    )
    .execute(&mut *tx)
    .await?;
    let queued: Option<(Uuid, String, serde_json::Value)> = sqlx::query_as(
        "SELECT id, recipient, payload FROM email_outbox WHERE sent_at IS NULL AND next_attempt_at <= now() ORDER BY created_at FOR UPDATE SKIP LOCKED LIMIT 1",
    )
    .fetch_optional(&mut *tx)
    .await?;
    let Some((id, recipient, payload)) = queued else {
        tx.commit().await?;
        return Ok(());
    };
    sqlx::query(
        "UPDATE email_outbox SET attempts = attempts + 1, next_attempt_at = now() + interval '5 minutes' WHERE id = $1",
    )
    .bind(id)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;

    let url = payload
        .get("url")
        .and_then(serde_json::Value::as_str)
        .context("email outbox payload has no URL")?;
    let recipient_mailbox: Mailbox = recipient.parse().context("parse queued recipient")?;
    let message = Message::builder()
        .from(from.clone())
        .to(recipient_mailbox)
        .subject("Your PTT Talk sign-in link")
        .body(format!(
            "Open this single-use link to continue signing in to PTT Talk:\n\n{url}\n\nThis link expires shortly. If you did not request it, ignore this email."
        ))?;
    match transport.send(message).await {
        Ok(_) => {
            sqlx::query(
                "UPDATE email_outbox SET sent_at = now(), last_error = NULL, payload = '{}'::jsonb WHERE id = $1",
            )
                .bind(id)
                .execute(pool)
                .await?;
        }
        Err(error) => {
            warn!(outbox_id = %id, "SMTP delivery failed");
            sqlx::query("UPDATE email_outbox SET last_error = $2 WHERE id = $1")
                .bind(id)
                .bind(sanitize_email_error(&error.to_string()))
                .execute(pool)
                .await?;
        }
    }
    Ok(())
}

async fn maintenance_worker(state: AppState) {
    let mut interval = tokio::time::interval(std::time::Duration::from_secs(60));
    loop {
        interval.tick().await;
        if let Err(error) = run_maintenance(&state).await {
            tracing::error!(error = %error, "control-plane maintenance failed");
        }
    }
}

async fn push_worker(state: AppState) {
    let mut interval = tokio::time::interval(std::time::Duration::from_secs(1));
    loop {
        interval.tick().await;
        if let Err(error) = dispatch_one_push(&state).await {
            tracing::error!(error = %error, "push delivery cycle failed");
        }
    }
}

async fn dispatch_one_push(state: &AppState) -> Result<()> {
    let mut tx = state.pool.begin().await?;
    let queued = sqlx::query_as::<_, PushOutboxRow>(
        "SELECT o.id, o.message_id, o.aci, o.device_id, o.provider, r.token, o.attempts FROM push_outbox o JOIN push_registrations r ON r.aci = o.aci AND r.device_id = o.device_id AND r.provider = o.provider JOIN devices d ON d.aci = o.aci AND d.device_id = o.device_id WHERE o.sent_at IS NULL AND o.next_attempt_at <= now() AND d.status = 'active' ORDER BY o.created_at FOR UPDATE OF o SKIP LOCKED LIMIT 1",
    )
    .fetch_optional(&mut *tx)
    .await?;
    let Some(queued) = queued else {
        tx.commit().await?;
        return Ok(());
    };
    let backoff_seconds = if state.push.has_provider(&queued.provider) {
        (5_i64 * 2_i64.saturating_pow(queued.attempts.clamp(0, 9) as u32)).min(3_600)
    } else {
        3_600
    };
    sqlx::query(
        "UPDATE push_outbox SET attempts = attempts + 1, next_attempt_at = now() + ($2 * interval '1 second') WHERE id = $1",
    )
    .bind(queued.id)
    .bind(backoff_seconds)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;

    let result = state
        .push
        .send(&queued.provider, &queued.token, queued.message_id)
        .await;
    match result {
        PushResult::Delivered => {
            sqlx::query("UPDATE push_outbox SET sent_at = now(), last_error = NULL WHERE id = $1")
                .bind(queued.id)
                .execute(&state.pool)
                .await?;
        }
        PushResult::InvalidRegistration => {
            let mut tx = state.pool.begin().await?;
            sqlx::query(
                "DELETE FROM push_registrations WHERE aci = $1 AND device_id = $2 AND provider = $3 AND token = $4",
            )
            .bind(queued.aci)
            .bind(queued.device_id)
            .bind(&queued.provider)
            .bind(&queued.token)
            .execute(&mut *tx)
            .await?;
            sqlx::query(
                "UPDATE push_outbox SET sent_at = now(), last_error = 'registration rejected by provider' WHERE id = $1",
            )
            .bind(queued.id)
            .execute(&mut *tx)
            .await?;
            tx.commit().await?;
        }
        PushResult::Retry => {
            sqlx::query(
                "UPDATE push_outbox SET last_error = 'provider delivery failed' WHERE id = $1",
            )
            .bind(queued.id)
            .execute(&state.pool)
            .await?;
        }
        PushResult::NotConfigured => {
            sqlx::query(
                "UPDATE push_outbox SET last_error = 'provider is not configured' WHERE id = $1",
            )
            .bind(queued.id)
            .execute(&state.pool)
            .await?;
        }
    }
    Ok(())
}

async fn run_maintenance(state: &AppState) -> Result<()> {
    sqlx::query(
        "UPDATE recovery_requests SET status='expired' WHERE status='pending_admin' AND expires_at <= now()",
    )
    .execute(&state.pool)
    .await?;
    let mailbox_deleted = sqlx::query(
        "DELETE FROM mailbox_items WHERE expires_at <= now() OR delivered_at < now() - interval '1 day'",
    )
    .execute(&state.pool)
    .await?
    .rows_affected();
    let chat_deleted = sqlx::query(
        "DELETE FROM chat_items WHERE expires_at <= now() OR delivered_at < now() - interval '1 day'",
    )
    .execute(&state.pool)
    .await?
    .rows_affected();
    let relay_deleted = sqlx::query("DELETE FROM relay_leases WHERE expires_at <= now()")
        .execute(&state.pool)
        .await?
        .rows_affected();
    let auth_deleted = sqlx::query(
        "DELETE FROM magic_links WHERE expires_at < now() - interval '30 days' OR consumed_at < now() - interval '30 days'",
    )
    .execute(&state.pool)
    .await?
    .rows_affected();
    sqlx::query(
        "DELETE FROM email_outbox WHERE sent_at < now() - interval '30 days' OR (sent_at IS NULL AND created_at < now() - interval '30 days')",
    )
    .execute(&state.pool)
    .await?;
    sqlx::query("DELETE FROM push_outbox WHERE sent_at < now() - interval '1 day'")
        .execute(&state.pool)
        .await?;

    let expired_history: Vec<(Uuid, String)> = sqlx::query_as(
        "SELECT object_id, storage_key FROM history_objects WHERE expires_at <= now() ORDER BY expires_at LIMIT 100",
    )
    .fetch_all(&state.pool)
    .await?;
    let mut history_deleted = 0_u64;
    for (object_id, storage_key) in expired_history {
        if let Err(error) = state.object_store.delete(&storage_key).await {
            warn!(kind = ?error, "expired history object deletion failed");
            continue;
        }
        history_deleted +=
            sqlx::query("DELETE FROM history_objects WHERE object_id = $1 AND expires_at <= now()")
                .bind(object_id)
                .execute(&state.pool)
                .await?
                .rows_affected();
    }
    let expired_chat: Vec<(Uuid, String)> = sqlx::query_as(
        "SELECT attachment_id, storage_key FROM chat_attachments WHERE expires_at <= now() ORDER BY expires_at LIMIT 100",
    )
    .fetch_all(&state.pool)
    .await?;
    let mut chat_attachments_deleted = 0_u64;
    for (attachment_id, storage_key) in expired_chat {
        if let Err(error) = state.object_store.delete(&storage_key).await {
            warn!(kind = ?error, "expired chat attachment deletion failed");
            continue;
        }
        chat_attachments_deleted += sqlx::query(
            "DELETE FROM chat_attachments WHERE attachment_id=$1 AND expires_at<=now()",
        )
        .bind(attachment_id)
        .execute(&state.pool)
        .await?
        .rows_affected();
    }
    let expired_uploads: Vec<Uuid> = sqlx::query_scalar(
        "SELECT upload_id FROM chat_attachment_uploads WHERE expires_at<=now() ORDER BY expires_at LIMIT 100",
    )
    .fetch_all(&state.pool)
    .await?;
    let mut chat_uploads_deleted = 0_u64;
    for upload_id in expired_uploads {
        let part_keys: Vec<String> = sqlx::query_scalar(
            "SELECT storage_key FROM chat_attachment_upload_parts WHERE upload_id=$1",
        )
        .bind(upload_id)
        .fetch_all(&state.pool)
        .await?;
        let mut all_deleted = true;
        for key in part_keys {
            if let Err(error) = state.object_store.delete(&key).await {
                warn!(kind = ?error, "expired chat upload part deletion failed");
                all_deleted = false;
            }
        }
        if all_deleted {
            chat_uploads_deleted += sqlx::query(
                "DELETE FROM chat_attachment_uploads WHERE upload_id=$1 AND expires_at<=now()",
            )
            .bind(upload_id)
            .execute(&state.pool)
            .await?
            .rows_affected();
        }
    }
    if mailbox_deleted
        + chat_deleted
        + relay_deleted
        + auth_deleted
        + history_deleted
        + chat_attachments_deleted
        + chat_uploads_deleted
        > 0
    {
        info!(
            mailbox_deleted,
            chat_deleted,
            relay_deleted,
            auth_deleted,
            history_deleted,
            chat_attachments_deleted,
            chat_uploads_deleted,
            "control-plane maintenance completed"
        );
    }
    Ok(())
}

fn sanitize_email_error(error: &str) -> String {
    let lowered = error.to_ascii_lowercase();
    if lowered.contains("authentication") || lowered.contains("credentials") {
        "SMTP authentication failed".to_owned()
    } else if lowered.contains("tls") || lowered.contains("certificate") {
        "SMTP TLS failed".to_owned()
    } else {
        "SMTP delivery failed".to_owned()
    }
}

fn app(state: AppState) -> Router {
    Router::new()
        .route("/healthz", get(health))
        .route("/readyz", get(ready))
        .route("/enroll", get(enrollment_landing))
        .route("/recover", get(recovery_landing))
        .route("/v1/bootstrap", post(bootstrap))
        .route("/v1/auth/magic-link/request", post(request_magic_link))
        .route("/v1/auth/magic-link/consume", post(consume_magic_link))
        .route("/v1/auth/recovery/request", post(request_recovery))
        .route("/v1/auth/recovery/consume", post(consume_recovery))
        .route("/v1/auth/recovery/status", post(recovery_status))
        .route("/v1/devices", get(list_devices))
        .route("/v1/account/delete", post(delete_account))
        .route("/v1/channels", get(device_channels))
        .route("/v1/channels/{channel_id}/devices", get(channel_devices))
        .route("/v1/devices/revoke", post(revoke_device))
        .route("/v1/devices/link/start", post(start_device_link))
        .route("/v1/devices/link/claim", post(claim_device_link))
        .route("/v1/devices/link/approve", post(approve_device_link))
        .route("/v1/devices/link/status", post(device_link_status))
        .route("/v1/prekeys/upload", post(upload_prekeys))
        .route("/v1/prekeys/fetch", post(fetch_prekeys))
        .route("/v1/mailbox/envelopes", post(enqueue_mailbox_envelopes))
        .route("/v1/mailbox/items", get(poll_mailbox))
        .route("/v1/mailbox/ack", post(acknowledge_mailbox_items))
        .route("/v1/chat/messages", post(enqueue_chat).get(poll_chat))
        .route("/v1/chat/ack", post(acknowledge_chat))
        .route(
            "/v1/chat/attachments/{attachment_id}",
            put(upload_chat_attachment)
                .get(download_chat_attachment)
                .layer(DefaultBodyLimit::max(MAX_CHAT_ATTACHMENT_BYTES)),
        )
        .route(
            "/v1/chat/attachments/{attachment_id}/uploads",
            post(create_chat_attachment_upload),
        )
        .route(
            "/v1/chat/attachments/{attachment_id}/uploads/{upload_id}",
            axum::routing::delete(cancel_chat_attachment_upload),
        )
        .route(
            "/v1/chat/attachments/{attachment_id}/uploads/{upload_id}/parts/{part_number}",
            put(upload_chat_attachment_part)
                .layer(DefaultBodyLimit::max(CHAT_ATTACHMENT_PART_BYTES)),
        )
        .route(
            "/v1/chat/attachments/{attachment_id}/uploads/{upload_id}/complete",
            post(complete_chat_attachment_upload),
        )
        .route(
            "/v1/push/registrations",
            post(register_push).delete(remove_push_registration),
        )
        .route("/v1/presence", post(set_presence))
        .route(
            "/v1/history/objects",
            get(list_history_objects)
                .post(upload_history_object)
                .layer(DefaultBodyLimit::max(
                    MAX_HISTORY_CIPHERTEXT_BYTES * 4 / 3 + 16_384,
                )),
        )
        .route(
            "/v1/history/objects/{object_id}",
            get(download_history_object),
        )
        .route("/v1/relay/credentials", post(relay_credentials))
        .route("/v1/media/tunnel", get(websocket_tunnel))
        .route("/v1/floor/request", post(request_floor))
        .route("/v1/floor/release", post(release_floor))
        .route("/v1/admin/summary", get(admin_summary))
        .route("/v1/admin/members", get(admin_members))
        .route("/v1/admin/devices", get(admin_devices))
        .route("/v1/admin/devices/revoke", post(admin_revoke_device))
        .route("/v1/admin/audit", get(admin_audit))
        .route("/v1/admin/operations", get(admin_operations))
        .route("/v1/admin/invitations", post(create_invitation))
        .route("/v1/admin/recoveries", get(admin_recoveries))
        .route("/v1/admin/recoveries/decision", post(decide_recovery))
        .route(
            "/v1/admin/channels",
            get(admin_channels).post(create_channel),
        )
        .route("/v1/admin/channels/members", get(admin_channel_members))
        .route(
            "/v1/admin/channels/membership",
            post(update_channel_membership),
        )
        .route("/v1/admin/channels/config", post(update_channel_config))
        .layer(TraceLayer::new_for_http())
        .layer(CatchPanicLayer::new())
        .layer(PropagateRequestIdLayer::new(HeaderName::from_static(
            "x-request-id",
        )))
        .layer(SetRequestIdLayer::new(
            HeaderName::from_static("x-request-id"),
            MakeRequestUuid,
        ))
        .with_state(state)
}

async fn set_presence(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<PresenceRequest>,
) -> Result<Json<AcceptedResponse>, ApiError> {
    let authenticated = require_device(&state.pool, &headers).await?;
    let class = match request.mode.as_str() {
        "available" => 1,
        "busy" => 2,
        "solo" => 3,
        "standby" => 4,
        _ => return Err(ApiError::bad_request("INVALID_PRESENCE")),
    };
    let key = format!(
        "ptt:v1:presence:{}:{}",
        authenticated.aci, authenticated.device_id
    );
    let mut connection = state.redis.get_multiplexed_async_connection().await?;
    redis::cmd("SET")
        .arg(key)
        .arg(class)
        .arg("EX")
        .arg(45)
        .query_async::<()>(&mut connection)
        .await?;
    Ok(Json(AcceptedResponse { accepted: true }))
}

async fn admin_summary(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<AdminSummary>, ApiError> {
    require_admin(&state.pool, &headers).await?;
    let accounts = sqlx::query_scalar("SELECT count(*) FROM accounts WHERE disabled_at IS NULL")
        .fetch_one(&state.pool)
        .await?;
    let active_devices = sqlx::query_scalar("SELECT count(*) FROM devices WHERE status = 'active'")
        .fetch_one(&state.pool)
        .await?;
    let channels = sqlx::query_scalar("SELECT count(*) FROM channels")
        .fetch_one(&state.pool)
        .await?;
    let pending_email =
        sqlx::query_scalar("SELECT count(*) FROM email_outbox WHERE sent_at IS NULL")
            .fetch_one(&state.pool)
            .await?;
    let pending_recoveries = sqlx::query_scalar(
        "SELECT count(*) FROM recovery_requests WHERE status='pending_admin' AND expires_at > now()",
    )
    .fetch_one(&state.pool)
    .await?;
    Ok(Json(AdminSummary {
        accounts,
        active_devices,
        channels,
        pending_email,
        pending_recoveries,
    }))
}

async fn admin_members(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Vec<MemberRow>>, ApiError> {
    require_admin(&state.pool, &headers).await?;
    let members = sqlx::query_as::<_, MemberRow>(
        "SELECT a.aci, a.email, a.is_admin, count(d.device_id) FILTER (WHERE d.status = 'active') AS active_devices FROM accounts a LEFT JOIN devices d ON d.aci = a.aci WHERE a.disabled_at IS NULL GROUP BY a.aci ORDER BY a.email",
    )
    .fetch_all(&state.pool)
    .await?;
    Ok(Json(members))
}

async fn admin_devices(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Vec<AdminDeviceRow>>, ApiError> {
    require_admin(&state.pool, &headers).await?;
    let devices = sqlx::query_as::<_, AdminDeviceRow>(
        "SELECT d.aci,a.email,d.device_id,d.display_name,d.status::text AS status,d.linked_at,d.revoked_at FROM devices d JOIN accounts a ON a.aci=d.aci WHERE a.disabled_at IS NULL ORDER BY lower(a.email),d.device_id",
    )
    .fetch_all(&state.pool)
    .await?;
    Ok(Json(devices))
}

async fn admin_audit(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<AdminAuditQuery>,
) -> Result<Json<Vec<AdminAuditRow>>, ApiError> {
    require_admin(&state.pool, &headers).await?;
    let limit = query.limit.unwrap_or(100);
    if !(1..=500).contains(&limit) {
        return Err(ApiError::bad_request("INVALID_LIMIT"));
    }
    let events = sqlx::query_as::<_, AdminAuditRow>(
        "SELECT event_id,action,encode(subject_hash,'hex') AS subject_hash,detail,created_at FROM audit_events ORDER BY created_at DESC LIMIT $1",
    )
    .bind(limit)
    .fetch_all(&state.pool)
    .await?;
    Ok(Json(events))
}

async fn admin_operations(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<AdminOperations>, ApiError> {
    require_admin(&state.pool, &headers).await?;
    let active_relay_leases =
        sqlx::query_scalar("SELECT count(*) FROM relay_leases WHERE expires_at > now()")
            .fetch_one(&state.pool)
            .await?;
    let pending_push = sqlx::query_scalar("SELECT count(*) FROM push_outbox WHERE sent_at IS NULL")
        .fetch_one(&state.pool)
        .await?;
    let failed_push = sqlx::query_scalar(
        "SELECT count(*) FROM push_outbox WHERE sent_at IS NULL AND attempts > 0",
    )
    .fetch_one(&state.pool)
    .await?;
    let history_objects = sqlx::query_scalar("SELECT count(*) FROM history_objects")
        .fetch_one(&state.pool)
        .await?;
    let backup_schedule = env::var("PTT_BACKUP_SCHEDULE").unwrap_or_default();
    let backup_configured = !backup_schedule.trim().is_empty();
    let canonical = format!(
        "v1|{}|{}|{}|{}|{}",
        state.public_base_url,
        state.relay_public_address,
        state.push.has_provider("fcm"),
        state.push.has_provider("apns"),
        backup_schedule,
    );
    let mut signer = Hmac::<Sha256>::new_from_slice(&state.relay_signing_key)
        .map_err(|_| ApiError::internal())?;
    signer.update(canonical.as_bytes());
    let configuration_fingerprint = hex::encode(&signer.finalize().into_bytes()[..12]);
    Ok(Json(AdminOperations {
        active_relay_leases,
        pending_push,
        failed_push,
        history_objects,
        fcm_configured: state.push.has_provider("fcm"),
        apns_configured: state.push.has_provider("apns"),
        backup_configured,
        backup_schedule,
        configuration_fingerprint,
    }))
}

async fn admin_recoveries(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Vec<AdminRecoveryRow>>, ApiError> {
    require_admin(&state.pool, &headers).await?;
    sqlx::query(
        "UPDATE recovery_requests SET status='expired' WHERE status='pending_admin' AND expires_at <= now()",
    )
    .execute(&state.pool)
    .await?;
    let recoveries = sqlx::query_as::<_, AdminRecoveryRow>(
        "SELECT r.request_id, a.email, r.device_name, r.status::text AS status, r.expires_at, r.created_at FROM recovery_requests r JOIN accounts a ON a.aci=r.aci WHERE r.status='pending_admin' ORDER BY r.created_at",
    )
    .fetch_all(&state.pool)
    .await?;
    Ok(Json(recoveries))
}

async fn decide_recovery(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<RecoveryDecisionRequest>,
) -> Result<Json<AcceptedResponse>, ApiError> {
    let actor = require_admin(&state.pool, &headers).await?;
    let mut tx = state.pool.begin().await?;
    let recovery: Option<PendingRecovery> = sqlx::query_as(
        "SELECT r.aci, r.mailbox_id, r.device_name, r.identity_key, r.access_token_sha256 FROM recovery_requests r JOIN accounts a ON a.aci=r.aci WHERE r.request_id=$1 AND r.status='pending_admin' AND r.expires_at > now() AND a.disabled_at IS NULL FOR UPDATE OF r",
    )
    .bind(request.request_id)
    .fetch_optional(&mut *tx)
    .await?;
    let (aci, mailbox_id, device_name, identity_key, access_token_sha256) =
        recovery.ok_or_else(|| ApiError::conflict("RECOVERY_NOT_PENDING"))?;
    if actor == aci {
        return Err(ApiError::forbidden_code("SELF_RECOVERY_APPROVAL_FORBIDDEN"));
    }

    let channel_ids: Vec<Uuid> = if request.approve {
        sqlx::query_scalar(
            "SELECT channel_id FROM memberships WHERE aci=$1 AND left_epoch IS NULL FOR UPDATE",
        )
        .bind(aci)
        .fetch_all(&mut *tx)
        .await?
    } else {
        Vec::new()
    };
    if request.approve {
        // Replacing the two-slot device set cascades old prekeys, push tokens,
        // mailbox items, link requests, and relay leases. The audit trail keeps
        // the revocation record without retaining usable device credentials.
        sqlx::query("DELETE FROM devices WHERE aci=$1")
            .bind(aci)
            .execute(&mut *tx)
            .await?;
        sqlx::query(
            "INSERT INTO devices(aci,device_id,mailbox_id,display_name,identity_key,access_token_sha256,status) VALUES($1,1,$2,$3,$4,$5,'active')",
        )
        .bind(aci)
        .bind(mailbox_id)
        .bind(device_name)
        .bind(identity_key)
        .bind(access_token_sha256)
        .execute(&mut *tx)
        .await?;
        sqlx::query(
            "UPDATE channels c SET membership_epoch=membership_epoch+1, distribution_id=gen_random_uuid() FROM memberships m WHERE m.channel_id=c.channel_id AND m.aci=$1 AND m.left_epoch IS NULL",
        )
        .bind(aci)
        .execute(&mut *tx)
        .await?;
    }
    let status = if request.approve {
        "approved"
    } else {
        "denied"
    };
    sqlx::query(
        "UPDATE recovery_requests SET status=$2::recovery_status, approved_by=$3, decided_at=now() WHERE request_id=$1",
    )
    .bind(request.request_id)
    .bind(status)
    .bind(actor)
    .execute(&mut *tx)
    .await?;
    sqlx::query(
        "INSERT INTO audit_events(actor_aci,action,subject_hash,detail) VALUES($1,$2,$3,jsonb_build_object('approved',$4,'rotatedChannels',$5))",
    )
    .bind(actor)
    .bind(if request.approve {
        "account.recovery_approved"
    } else {
        "account.recovery_denied"
    })
    .bind(hash_secret(&aci.to_string()).as_slice())
    .bind(request.approve)
    .bind(channel_ids.len() as i32)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;

    if request.approve && !channel_ids.is_empty() {
        if let Ok(mut redis) = state.redis.get_multiplexed_async_connection().await {
            for channel_id in channel_ids {
                let _: Result<i32, _> = redis::cmd("DEL")
                    .arg(format!("ptt:v1:floor:{channel_id}"))
                    .query_async(&mut redis)
                    .await;
            }
        }
    }
    Ok(Json(AcceptedResponse { accepted: true }))
}

async fn admin_channels(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Vec<AdminChannelRow>>, ApiError> {
    require_admin(&state.pool, &headers).await?;
    let channels = sqlx::query_as::<_, AdminChannelRow>(
        "SELECT c.channel_id, c.display_name, c.kind, c.membership_epoch, c.retention_days, count(m.aci) FILTER (WHERE m.left_epoch IS NULL) AS active_members FROM channels c LEFT JOIN memberships m ON m.channel_id = c.channel_id GROUP BY c.channel_id ORDER BY lower(c.display_name)",
    )
    .fetch_all(&state.pool)
    .await?;
    Ok(Json(channels))
}

async fn admin_channel_members(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<AdminChannelMembersQuery>,
) -> Result<Json<Vec<AdminChannelMemberRow>>, ApiError> {
    require_admin(&state.pool, &headers).await?;
    if query.channel_id.is_nil() {
        return Err(ApiError::bad_request("INVALID_CHANNEL_ID"));
    }
    let exists: bool =
        sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM channels WHERE channel_id = $1)")
            .bind(query.channel_id)
            .fetch_one(&state.pool)
            .await?;
    if !exists {
        return Err(ApiError::bad_request("UNKNOWN_CHANNEL"));
    }
    let members = sqlx::query_as::<_, AdminChannelMemberRow>(
        "SELECT m.channel_id,m.aci,a.email,m.role,m.joined_epoch FROM memberships m JOIN accounts a ON a.aci=m.aci WHERE m.channel_id=$1 AND m.left_epoch IS NULL AND a.disabled_at IS NULL ORDER BY lower(a.email)",
    )
    .bind(query.channel_id)
    .fetch_all(&state.pool)
    .await?;
    Ok(Json(members))
}

async fn create_channel(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<CreateChannelRequest>,
) -> Result<Json<AdminChannelRow>, ApiError> {
    let actor = require_admin(&state.pool, &headers).await?;
    let display_name = request.display_name.trim();
    if display_name.is_empty() || display_name.len() > 80 {
        return Err(ApiError::bad_request("INVALID_CHANNEL_NAME"));
    }
    if !matches!(request.kind.as_str(), "team" | "duty" | "adhoc" | "direct") {
        return Err(ApiError::bad_request("INVALID_CHANNEL_KIND"));
    }
    if !(1..=365).contains(&request.retention_days) {
        return Err(ApiError::bad_request("INVALID_RETENTION"));
    }
    if request.members.is_empty() || request.members.len() > 64 {
        return Err(ApiError::bad_request("INVALID_MEMBERS"));
    }
    if request.kind == "direct" && request.members.len() != 2 {
        return Err(ApiError::bad_request("DIRECT_REQUIRES_TWO_MEMBERS"));
    }
    let mut unique_members = std::collections::HashSet::new();
    for member in &request.members {
        if !unique_members.insert(member.aci) || !valid_role(&member.role) {
            return Err(ApiError::bad_request("INVALID_MEMBERS"));
        }
    }

    let channel_id = Uuid::new_v4();
    let mut tx = state.pool.begin().await?;
    sqlx::query(
        "INSERT INTO channels(channel_id, display_name, kind, distribution_id, retention_days) VALUES ($1, $2, $3, $4, $5)",
    )
    .bind(channel_id)
    .bind(display_name)
    .bind(&request.kind)
    .bind(Uuid::new_v4())
    .bind(request.retention_days)
    .execute(&mut *tx)
    .await?;
    for member in &request.members {
        let exists: bool = sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM accounts WHERE aci = $1 AND disabled_at IS NULL)",
        )
        .bind(member.aci)
        .fetch_one(&mut *tx)
        .await?;
        if !exists {
            return Err(ApiError::bad_request("UNKNOWN_MEMBER"));
        }
        sqlx::query(
            "INSERT INTO memberships(channel_id, aci, role, joined_epoch) VALUES ($1, $2, $3, 1)",
        )
        .bind(channel_id)
        .bind(member.aci)
        .bind(&member.role)
        .execute(&mut *tx)
        .await?;
    }
    sqlx::query(
        "INSERT INTO audit_events(actor_aci, action, subject_hash, detail) VALUES ($1, 'channel.created', $2, jsonb_build_object('members', $3))",
    )
    .bind(actor)
    .bind(hash_secret(&channel_id.to_string()).as_slice())
    .bind(request.members.len() as i32)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(Json(AdminChannelRow {
        channel_id,
        display_name: display_name.to_owned(),
        kind: request.kind,
        membership_epoch: 1,
        retention_days: request.retention_days,
        active_members: request.members.len() as i64,
    }))
}

async fn update_channel_config(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<UpdateChannelConfigRequest>,
) -> Result<Json<AdminChannelRow>, ApiError> {
    let actor = require_admin(&state.pool, &headers).await?;
    let display_name = request.display_name.trim();
    if display_name.is_empty() || display_name.len() > 80 {
        return Err(ApiError::bad_request("INVALID_CHANNEL_NAME"));
    }
    if !(1..=365).contains(&request.retention_days) {
        return Err(ApiError::bad_request("INVALID_RETENTION"));
    }
    let mut tx = state.pool.begin().await?;
    let updated = sqlx::query_as::<_, AdminChannelRow>(
        "UPDATE channels c SET display_name=$2,retention_days=$3 WHERE c.channel_id=$1 RETURNING c.channel_id,c.display_name,c.kind,c.membership_epoch,c.retention_days,(SELECT count(*) FROM memberships m WHERE m.channel_id=c.channel_id AND m.left_epoch IS NULL) AS active_members",
    )
    .bind(request.channel_id)
    .bind(display_name)
    .bind(request.retention_days)
    .fetch_optional(&mut *tx)
    .await?
    .ok_or_else(|| ApiError::bad_request("UNKNOWN_CHANNEL"))?;
    sqlx::query(
        "INSERT INTO audit_events(actor_aci,action,subject_hash,detail) VALUES($1,'channel.config_changed',$2,jsonb_build_object('retentionDays',$3))",
    )
    .bind(actor)
    .bind(hash_secret(&request.channel_id.to_string()).as_slice())
    .bind(request.retention_days)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(Json(updated))
}

async fn update_channel_membership(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<UpdateMembershipRequest>,
) -> Result<Json<AcceptedResponse>, ApiError> {
    let actor = require_admin(&state.pool, &headers).await?;
    if request.remove == request.role.is_some() {
        return Err(ApiError::bad_request("INVALID_MEMBERSHIP_CHANGE"));
    }
    if request
        .role
        .as_deref()
        .is_some_and(|role| !valid_role(role))
    {
        return Err(ApiError::bad_request("INVALID_ROLE"));
    }
    let mut tx = state.pool.begin().await?;
    let channel: Option<(i32, String)> = sqlx::query_as(
        "UPDATE channels SET membership_epoch = membership_epoch + 1, distribution_id = gen_random_uuid() WHERE channel_id = $1 RETURNING membership_epoch,kind",
    )
    .bind(request.channel_id)
    .fetch_optional(&mut *tx)
    .await?;
    let (epoch, channel_kind) = channel.ok_or_else(|| ApiError::bad_request("UNKNOWN_CHANNEL"))?;
    if request.remove {
        let changed = sqlx::query(
            "UPDATE memberships SET left_epoch = $3 WHERE channel_id = $1 AND aci = $2 AND left_epoch IS NULL",
        )
        .bind(request.channel_id)
        .bind(request.aci)
        .bind(epoch)
        .execute(&mut *tx)
        .await?;
        if changed.rows_affected() != 1 {
            return Err(ApiError::bad_request("UNKNOWN_MEMBERSHIP"));
        }
    } else {
        let account_exists: bool = sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM accounts WHERE aci=$1 AND disabled_at IS NULL)",
        )
        .bind(request.aci)
        .fetch_one(&mut *tx)
        .await?;
        if !account_exists {
            return Err(ApiError::bad_request("UNKNOWN_MEMBER"));
        }
        let already_active: bool = sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM memberships WHERE channel_id=$1 AND aci=$2 AND left_epoch IS NULL)",
        )
        .bind(request.channel_id)
        .bind(request.aci)
        .fetch_one(&mut *tx)
        .await?;
        if !already_active {
            let member_count: i64 = sqlx::query_scalar(
                "SELECT count(*) FROM memberships WHERE channel_id = $1 AND left_epoch IS NULL",
            )
            .bind(request.channel_id)
            .fetch_one(&mut *tx)
            .await?;
            let member_limit = if channel_kind == "direct" { 2 } else { 64 };
            if member_count >= member_limit {
                return Err(ApiError::conflict("CHANNEL_MEMBER_LIMIT"));
            }
        }
        sqlx::query(
            "INSERT INTO memberships(channel_id, aci, role, joined_epoch, left_epoch) VALUES ($1, $2, $3, $4, NULL) ON CONFLICT(channel_id, aci) DO UPDATE SET role=excluded.role, joined_epoch=CASE WHEN memberships.left_epoch IS NULL THEN memberships.joined_epoch ELSE excluded.joined_epoch END, left_epoch=NULL",
        )
        .bind(request.channel_id)
        .bind(request.aci)
        .bind(request.role.as_deref().expect("validated role"))
        .bind(epoch)
        .execute(&mut *tx)
        .await?;
    }
    sqlx::query(
        "INSERT INTO audit_events(actor_aci, action, subject_hash, detail) VALUES ($1, 'channel.membership_changed', $2, jsonb_build_object('epoch', $3, 'removed', $4))",
    )
    .bind(actor)
    .bind(hash_secret(&format!("{}:{}", request.channel_id, request.aci)).as_slice())
    .bind(epoch)
    .bind(request.remove)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(Json(AcceptedResponse { accepted: true }))
}

fn valid_role(role: &str) -> bool {
    matches!(
        role,
        "talk" | "listen" | "barge" | "dispatch" | "emergency-target"
    )
}

async fn create_invitation(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<CreateInvitationRequest>,
) -> Result<Json<InvitationResponse>, ApiError> {
    let actor = require_admin(&state.pool, &headers).await?;
    validate_email(&request.email)?;
    let secret = IssuedSecret::issue();
    let expires_at = Utc::now() + Duration::days(7);
    let invitation_id = Uuid::new_v4();
    let mut tx = state.pool.begin().await?;
    sqlx::query(
        "INSERT INTO invitations (id, email, token_sha256, grants_admin, expires_at) VALUES ($1, lower($2), $3, false, $4)",
    )
    .bind(invitation_id)
    .bind(request.email.trim())
    .bind(secret.sha256.as_slice())
    .bind(expires_at)
    .execute(&mut *tx)
    .await?;
    issue_magic_link(&mut tx, &state, invitation_id, request.email.trim(), false).await?;
    sqlx::query(
        "INSERT INTO audit_events (actor_aci, action, subject_hash) VALUES ($1, 'invitation.created', $2)",
    )
    .bind(actor)
    .bind(hash_secret(request.email.trim()).as_slice())
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(Json(InvitationResponse {
        invitation_code: secret.plaintext,
        expires_at,
    }))
}

async fn require_admin(pool: &PgPool, headers: &HeaderMap) -> Result<Uuid, ApiError> {
    let authenticated = require_device(pool, headers).await?;
    if !authenticated.is_admin {
        return Err(ApiError::forbidden());
    }
    Ok(authenticated.aci)
}

async fn require_device(
    pool: &PgPool,
    headers: &HeaderMap,
) -> Result<AuthenticatedDevice, ApiError> {
    let token = headers
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .filter(|value| !value.is_empty())
        .ok_or_else(ApiError::unauthenticated)?;
    let token_hash = hash_secret(token);
    sqlx::query_as::<_, (Uuid, i32, bool)>(
        "SELECT a.aci, d.device_id, a.is_admin FROM accounts a JOIN devices d ON d.aci = a.aci WHERE d.access_token_sha256 = $1 AND d.status = 'active' AND a.disabled_at IS NULL",
    )
    .bind(token_hash.as_slice())
    .fetch_optional(pool)
    .await?
    .ok_or_else(ApiError::unauthenticated)
    .map(|(aci, device_id, is_admin)| AuthenticatedDevice {
        aci,
        device_id,
        is_admin,
        access_token_sha256: token_hash,
    })
}

async fn list_devices(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Vec<DeviceRow>>, ApiError> {
    let authenticated = require_device(&state.pool, &headers).await?;
    let devices = sqlx::query_as::<_, DeviceRow>(
        "SELECT device_id, mailbox_id, display_name, status::text AS status, linked_at, revoked_at FROM devices WHERE aci = $1 ORDER BY device_id",
    )
    .bind(authenticated.aci)
    .fetch_all(&state.pool)
    .await?;
    Ok(Json(devices))
}

async fn delete_account(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<DeleteAccountRequest>,
) -> Result<Json<AcceptedResponse>, ApiError> {
    if request.confirmation != "DELETE" {
        return Err(ApiError::bad_request(
            "ACCOUNT_DELETE_CONFIRMATION_REQUIRED",
        ));
    }
    let authenticated = require_device(&state.pool, &headers).await?;
    let mut tx = state.pool.begin().await?;
    let account: Option<(String, bool)> = sqlx::query_as(
        "SELECT email,is_admin FROM accounts WHERE aci=$1 AND disabled_at IS NULL FOR UPDATE",
    )
    .bind(authenticated.aci)
    .fetch_optional(&mut *tx)
    .await?;
    let (email, is_admin) = account.ok_or_else(ApiError::unauthenticated)?;
    if is_admin {
        let other_admin_devices: i64 = sqlx::query_scalar(
            "SELECT count(*) FROM devices d JOIN accounts a ON a.aci=d.aci WHERE a.is_admin AND a.disabled_at IS NULL AND d.status='active' AND a.aci<>$1",
        )
        .bind(authenticated.aci)
        .fetch_one(&mut *tx)
        .await?;
        if other_admin_devices == 0 {
            return Err(ApiError::conflict("LAST_ADMIN_ACCOUNT"));
        }
    }

    let channel_ids: Vec<Uuid> = sqlx::query_scalar(
        "SELECT channel_id FROM memberships WHERE aci=$1 AND left_epoch IS NULL FOR UPDATE",
    )
    .bind(authenticated.aci)
    .fetch_all(&mut *tx)
    .await?;
    if !channel_ids.is_empty() {
        sqlx::query(
            "UPDATE channels SET membership_epoch=membership_epoch+1,distribution_id=gen_random_uuid() WHERE channel_id=ANY($1)",
        )
        .bind(&channel_ids)
        .execute(&mut *tx)
        .await?;
        sqlx::query(
            "UPDATE memberships m SET left_epoch=c.membership_epoch FROM channels c WHERE m.channel_id=c.channel_id AND m.aci=$1 AND m.left_epoch IS NULL",
        )
        .bind(authenticated.aci)
        .execute(&mut *tx)
        .await?;
    }

    sqlx::query("DELETE FROM email_outbox WHERE recipient=$1")
        .bind(&email)
        .execute(&mut *tx)
        .await?;
    sqlx::query("DELETE FROM invitations WHERE email=$1")
        .bind(&email)
        .execute(&mut *tx)
        .await?;
    sqlx::query("DELETE FROM magic_links WHERE email=$1")
        .bind(&email)
        .execute(&mut *tx)
        .await?;
    sqlx::query("DELETE FROM recovery_requests WHERE aci=$1")
        .bind(authenticated.aci)
        .execute(&mut *tx)
        .await?;
    sqlx::query("DELETE FROM devices WHERE aci=$1")
        .bind(authenticated.aci)
        .execute(&mut *tx)
        .await?;
    sqlx::query("UPDATE audit_events SET actor_aci=NULL WHERE actor_aci=$1")
        .bind(authenticated.aci)
        .execute(&mut *tx)
        .await?;
    let deleted_email = format!("deleted+{}@invalid.ptt", authenticated.aci.simple());
    sqlx::query("UPDATE accounts SET email=$2,is_admin=false,disabled_at=now() WHERE aci=$1")
        .bind(authenticated.aci)
        .bind(deleted_email)
        .execute(&mut *tx)
        .await?;
    sqlx::query(
        "INSERT INTO audit_events(action,subject_hash,detail) VALUES('account.deleted',$1,jsonb_build_object('rotatedChannels',$2))",
    )
    .bind(hash_secret(&authenticated.aci.to_string()).as_slice())
    .bind(channel_ids.len() as i32)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;

    if let Ok(mut redis) = state.redis.get_multiplexed_async_connection().await {
        for channel_id in channel_ids {
            let _: Result<i32, _> = redis::cmd("DEL")
                .arg(format!("ptt:v1:floor:{channel_id}"))
                .query_async(&mut redis)
                .await;
        }
    }
    Ok(Json(AcceptedResponse { accepted: true }))
}

async fn device_channels(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Vec<DeviceChannelRow>>, ApiError> {
    let authenticated = require_device(&state.pool, &headers).await?;
    let channels = sqlx::query_as::<_, DeviceChannelRow>(
        "SELECT c.channel_id,c.display_name,c.kind,c.distribution_id,c.membership_epoch,c.retention_days,m.role FROM channels c JOIN memberships m ON m.channel_id=c.channel_id WHERE m.aci=$1 AND m.left_epoch IS NULL ORDER BY lower(c.display_name)",
    )
    .bind(authenticated.aci)
    .fetch_all(&state.pool)
    .await?;
    Ok(Json(channels))
}

async fn channel_devices(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(channel_id): Path<Uuid>,
) -> Result<Json<Vec<ChannelDeviceResponse>>, ApiError> {
    let authenticated = require_device(&state.pool, &headers).await?;
    if channel_id.is_nil() {
        return Err(ApiError::bad_request("INVALID_CHANNEL_ID"));
    }
    let authorized: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM memberships WHERE channel_id = $1 AND aci = $2 AND left_epoch IS NULL)",
    )
    .bind(channel_id)
    .bind(authenticated.aci)
    .fetch_one(&state.pool)
    .await?;
    if !authorized {
        return Err(ApiError::forbidden());
    }
    let rows: Vec<(Uuid, i32, Uuid, Vec<u8>, String)> = sqlx::query_as(
        "SELECT d.aci, d.device_id, d.mailbox_id, d.identity_key, m.role FROM memberships m JOIN devices d ON d.aci = m.aci JOIN accounts a ON a.aci = d.aci WHERE m.channel_id = $1 AND m.left_epoch IS NULL AND d.status = 'active' AND a.disabled_at IS NULL ORDER BY d.aci, d.device_id",
    )
    .bind(channel_id)
    .fetch_all(&state.pool)
    .await?;
    Ok(Json(
        rows.into_iter()
            .map(
                |(aci, device_id, mailbox_id, identity_key, role)| ChannelDeviceResponse {
                    aci,
                    device_id,
                    mailbox_id,
                    identity_key: URL_SAFE_NO_PAD.encode(identity_key),
                    role,
                },
            )
            .collect(),
    ))
}

async fn start_device_link(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<DeviceLinkStartResponse>, ApiError> {
    let authenticated = require_device(&state.pool, &headers).await?;
    let mut tx = state.pool.begin().await?;
    sqlx::query(
        "DELETE FROM devices d USING device_link_requests r WHERE r.aci = $1 AND r.aci = d.aci AND r.claimed_device_id = d.device_id AND r.approved_at IS NULL AND r.expires_at <= now() AND d.status = 'pending'",
    )
    .bind(authenticated.aci)
    .execute(&mut *tx)
    .await?;
    let device_count: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM devices WHERE aci = $1 AND status IN ('active', 'pending')",
    )
    .bind(authenticated.aci)
    .fetch_one(&mut *tx)
    .await?;
    if device_count >= 2 {
        return Err(ApiError::device_limit());
    }
    let request_id = Uuid::new_v4();
    let code = IssuedSecret::issue();
    let expires_at = Utc::now() + Duration::minutes(10);
    sqlx::query(
        "INSERT INTO device_link_requests(request_id, aci, initiator_device_id, qr_token_sha256, expires_at) VALUES ($1, $2, $3, $4, $5)",
    )
    .bind(request_id)
    .bind(authenticated.aci)
    .bind(authenticated.device_id)
    .bind(code.sha256.as_slice())
    .bind(expires_at)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(Json(DeviceLinkStartResponse {
        request_id,
        link_code: code.plaintext,
        expires_at,
    }))
}

async fn claim_device_link(
    State(state): State<AppState>,
    Json(request): Json<DeviceLinkClaimRequest>,
) -> Result<Json<DeviceLinkClaimResponse>, ApiError> {
    if request.device_name.trim().is_empty() || request.device_name.len() > 80 {
        return Err(ApiError::bad_request("INVALID_DEVICE_NAME"));
    }
    let identity_key = decode_sized(&request.identity_key, 32, 4096, "INVALID_IDENTITY_KEY")?;
    let code_hash = hash_secret(&request.link_code);
    let mut tx = state.pool.begin().await?;
    let link: Option<(Uuid,)> = sqlx::query_as(
        "SELECT aci FROM device_link_requests WHERE request_id = $1 AND qr_token_sha256 = $2 AND claimed_device_id IS NULL AND consumed_at IS NULL AND expires_at > now() FOR UPDATE",
    )
    .bind(request.request_id)
    .bind(code_hash.as_slice())
    .fetch_optional(&mut *tx)
    .await?;
    let (aci,) = link.ok_or_else(ApiError::invalid_or_expired_link)?;
    let occupied: Vec<i32> = sqlx::query_scalar(
        "SELECT device_id FROM devices WHERE aci = $1 AND status IN ('active', 'pending') ORDER BY device_id FOR UPDATE",
    )
    .bind(aci)
    .fetch_all(&mut *tx)
    .await?;
    let device_id = (1..=2)
        .find(|candidate| !occupied.contains(candidate))
        .ok_or_else(ApiError::device_limit)?;
    sqlx::query("DELETE FROM devices WHERE aci = $1 AND device_id = $2 AND status = 'revoked'")
        .bind(aci)
        .bind(device_id)
        .execute(&mut *tx)
        .await?;
    let mailbox_id = Uuid::new_v4();
    let claim_token = IssuedSecret::issue();
    sqlx::query(
        "INSERT INTO devices(aci, device_id, mailbox_id, display_name, identity_key, access_token_sha256, status) VALUES ($1, $2, $3, $4, $5, $6, 'pending')",
    )
    .bind(aci)
    .bind(device_id)
    .bind(mailbox_id)
    .bind(request.device_name.trim())
    .bind(identity_key)
    .bind(claim_token.sha256.as_slice())
    .execute(&mut *tx)
    .await?;
    sqlx::query(
        "UPDATE device_link_requests SET claimed_device_id = $2, consumed_at = now() WHERE request_id = $1",
    )
    .bind(request.request_id)
    .bind(device_id)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(Json(DeviceLinkClaimResponse {
        aci,
        device_id,
        mailbox_id,
        claim_token: claim_token.plaintext,
        status: "pending",
    }))
}

async fn approve_device_link(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<DeviceLinkApproveRequest>,
) -> Result<Json<AcceptedResponse>, ApiError> {
    let authenticated = require_device(&state.pool, &headers).await?;
    let mut tx = state.pool.begin().await?;
    let claimed_device_id: Option<i32> = sqlx::query_scalar(
        "SELECT claimed_device_id FROM device_link_requests WHERE request_id = $1 AND aci = $2 AND initiator_device_id = $3 AND claimed_device_id IS NOT NULL AND approved_at IS NULL AND expires_at > now() FOR UPDATE",
    )
    .bind(request.request_id)
    .bind(authenticated.aci)
    .bind(authenticated.device_id)
    .fetch_optional(&mut *tx)
    .await?
    .flatten();
    let claimed_device_id = claimed_device_id.ok_or_else(ApiError::invalid_or_expired_link)?;
    let channel_ids: Vec<Uuid> = sqlx::query_scalar(
        "SELECT channel_id FROM memberships WHERE aci=$1 AND left_epoch IS NULL FOR UPDATE",
    )
    .bind(authenticated.aci)
    .fetch_all(&mut *tx)
    .await?;
    sqlx::query(
        "UPDATE devices SET status = 'active', linked_at = now() WHERE aci = $1 AND device_id = $2 AND status = 'pending'",
    )
    .bind(authenticated.aci)
    .bind(claimed_device_id)
    .execute(&mut *tx)
    .await?;
    sqlx::query(
        "UPDATE channels c SET membership_epoch=membership_epoch+1, distribution_id=gen_random_uuid() FROM memberships m WHERE m.channel_id=c.channel_id AND m.aci=$1 AND m.left_epoch IS NULL",
    )
    .bind(authenticated.aci)
    .execute(&mut *tx)
    .await?;
    sqlx::query("UPDATE device_link_requests SET approved_at = now() WHERE request_id = $1")
        .bind(request.request_id)
        .execute(&mut *tx)
        .await?;
    sqlx::query(
        "INSERT INTO audit_events(actor_aci, action, subject_hash, detail) VALUES ($1, 'device.linked', $2, jsonb_build_object('deviceId', $3, 'rotatedChannels', $4))",
    )
    .bind(authenticated.aci)
    .bind(hash_secret(&format!(
        "{}:{}",
        authenticated.aci, claimed_device_id
    )).as_slice())
    .bind(claimed_device_id)
    .bind(channel_ids.len() as i32)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    if !channel_ids.is_empty() {
        if let Ok(mut redis) = state.redis.get_multiplexed_async_connection().await {
            for channel_id in channel_ids {
                let _: Result<i32, _> = redis::cmd("DEL")
                    .arg(format!("ptt:v1:floor:{channel_id}"))
                    .query_async(&mut redis)
                    .await;
            }
        }
    }
    Ok(Json(AcceptedResponse { accepted: true }))
}

async fn device_link_status(
    State(state): State<AppState>,
    Json(request): Json<DeviceLinkStatusRequest>,
) -> Result<Json<DeviceLinkStatusResponse>, ApiError> {
    let token_hash = hash_secret(&request.claim_token);
    let result: Option<(Uuid, i32, Uuid, String)> = sqlx::query_as(
        "SELECT d.aci, d.device_id, d.mailbox_id, d.status::text FROM devices d WHERE d.access_token_sha256 = $1 AND (d.status = 'active' OR (d.status = 'pending' AND EXISTS(SELECT 1 FROM device_link_requests r WHERE r.aci = d.aci AND r.claimed_device_id = d.device_id AND r.approved_at IS NULL AND r.expires_at > now())))",
    )
    .bind(token_hash.as_slice())
    .fetch_optional(&state.pool)
    .await?;
    let (aci, device_id, mailbox_id, status) =
        result.ok_or_else(ApiError::invalid_or_expired_link)?;
    Ok(Json(DeviceLinkStatusResponse {
        aci,
        device_id,
        mailbox_id,
        status,
    }))
}

async fn revoke_device(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<RevokeDeviceRequest>,
) -> Result<Json<AcceptedResponse>, ApiError> {
    let authenticated = require_device(&state.pool, &headers).await?;
    revoke_device_for(
        &state,
        authenticated.aci,
        authenticated.aci,
        request.device_id,
    )
    .await?;
    Ok(Json(AcceptedResponse { accepted: true }))
}

async fn admin_revoke_device(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<AdminRevokeDeviceRequest>,
) -> Result<Json<AcceptedResponse>, ApiError> {
    let actor = require_admin(&state.pool, &headers).await?;
    revoke_device_for(&state, actor, request.aci, request.device_id).await?;
    Ok(Json(AcceptedResponse { accepted: true }))
}

async fn revoke_device_for(
    state: &AppState,
    actor: Uuid,
    target_aci: Uuid,
    target_device_id: i32,
) -> Result<(), ApiError> {
    if !(1..=2).contains(&target_device_id) {
        return Err(ApiError::bad_request("INVALID_DEVICE_ID"));
    }
    let mut tx = state.pool.begin().await?;
    let target_is_admin: Option<bool> = sqlx::query_scalar(
        "SELECT a.is_admin FROM devices d JOIN accounts a ON a.aci=d.aci WHERE d.aci=$1 AND d.device_id=$2 AND d.status='active' AND a.disabled_at IS NULL FOR UPDATE OF d",
    )
    .bind(target_aci)
    .bind(target_device_id)
    .fetch_optional(&mut *tx)
    .await?;
    let target_is_admin = target_is_admin.ok_or_else(|| ApiError::conflict("DEVICE_NOT_ACTIVE"))?;

    if target_is_admin {
        let other_admin_devices: i64 = sqlx::query_scalar(
            "SELECT count(*) FROM devices d JOIN accounts a ON a.aci = d.aci WHERE a.is_admin AND a.disabled_at IS NULL AND d.status = 'active' AND NOT (d.aci = $1 AND d.device_id = $2)",
        )
        .bind(target_aci)
        .bind(target_device_id)
        .fetch_one(&mut *tx)
        .await?;
        if other_admin_devices == 0 {
            return Err(ApiError::conflict("LAST_ADMIN_DEVICE"));
        }
    }

    let invalidated_access = IssuedSecret::issue();
    sqlx::query(
        "UPDATE devices SET status = 'revoked', revoked_at = now(), access_token_sha256 = $3 WHERE aci = $1 AND device_id = $2",
    )
    .bind(target_aci)
    .bind(target_device_id)
    .bind(invalidated_access.sha256.as_slice())
    .execute(&mut *tx)
    .await?;
    sqlx::query(
        "UPDATE channels c SET membership_epoch = membership_epoch + 1, distribution_id = gen_random_uuid() FROM memberships m WHERE m.channel_id = c.channel_id AND m.aci = $1 AND m.left_epoch IS NULL",
    )
    .bind(target_aci)
    .execute(&mut *tx)
    .await?;
    sqlx::query(
        "INSERT INTO audit_events(actor_aci, action, subject_hash, detail) VALUES ($1, 'device.revoked', $3, jsonb_build_object('deviceId', $2))",
    )
    .bind(actor)
    .bind(target_device_id)
    .bind(hash_secret(&format!("{}:{}", target_aci, target_device_id)).as_slice())
    .execute(&mut *tx)
    .await?;
    let channel_ids: Vec<Uuid> = sqlx::query_scalar(
        "SELECT channel_id FROM memberships WHERE aci=$1 AND left_epoch IS NULL",
    )
    .bind(target_aci)
    .fetch_all(&mut *tx)
    .await?;
    tx.commit().await?;
    if let Ok(mut redis) = state.redis.get_multiplexed_async_connection().await {
        for channel_id in channel_ids {
            let _: Result<i32, _> = redis::cmd("DEL")
                .arg(format!("ptt:v1:floor:{channel_id}"))
                .query_async(&mut redis)
                .await;
        }
    }
    Ok(())
}

async fn upload_prekeys(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<UploadPreKeysRequest>,
) -> Result<Json<AcceptedResponse>, ApiError> {
    let authenticated = require_device(&state.pool, &headers).await?;
    let bundle = decode_sized(&request.opaque_bundle, 32, 65_536, "INVALID_PREKEY_BUNDLE")?;
    if request.one_time_prekeys.len() > 200 {
        return Err(ApiError::bad_request("TOO_MANY_PREKEYS"));
    }
    let mut decoded = Vec::with_capacity(request.one_time_prekeys.len());
    for item in request.one_time_prekeys {
        if (item.kind != "x25519" && item.kind != "kyber") || item.key_id <= 0 {
            return Err(ApiError::bad_request("INVALID_PREKEY_KIND"));
        }
        decoded.push((
            item.kind,
            item.key_id,
            decode_sized(&item.public_key, 32, 4096, "INVALID_PREKEY")?,
        ));
    }

    let mut tx = state.pool.begin().await?;
    sqlx::query(
        "INSERT INTO prekey_bundles(aci, device_id, opaque_bundle) VALUES ($1, $2, $3) ON CONFLICT(aci, device_id) DO UPDATE SET opaque_bundle = excluded.opaque_bundle, updated_at = now()",
    )
    .bind(authenticated.aci)
    .bind(authenticated.device_id)
    .bind(bundle)
    .execute(&mut *tx)
    .await?;
    for (kind, key_id, public_key) in decoded {
        let existing: Option<Vec<u8>> = sqlx::query_scalar(
            "SELECT public_key FROM one_time_prekeys WHERE aci = $1 AND device_id = $2 AND kind = $3 AND key_id = $4",
        )
        .bind(authenticated.aci)
        .bind(authenticated.device_id)
        .bind(&kind)
        .bind(key_id)
        .fetch_optional(&mut *tx)
        .await?;
        match existing {
            Some(existing) if existing != public_key => {
                return Err(ApiError::conflict("PREKEY_ID_REUSED"));
            }
            Some(_) => {}
            None => {
                sqlx::query(
                    "INSERT INTO one_time_prekeys(aci, device_id, kind, key_id, public_key) VALUES ($1, $2, $3, $4, $5)",
                )
                .bind(authenticated.aci)
                .bind(authenticated.device_id)
                .bind(kind)
                .bind(key_id)
                .bind(public_key)
                .execute(&mut *tx)
                .await?;
            }
        }
    }
    tx.commit().await?;
    Ok(Json(AcceptedResponse { accepted: true }))
}

async fn fetch_prekeys(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<FetchPreKeysRequest>,
) -> Result<Json<Vec<PreKeyBundleResponse>>, ApiError> {
    let authenticated = require_device(&state.pool, &headers).await?;
    if request.devices.is_empty() || request.devices.len() > MAX_PREKEY_BATCH_DEVICES {
        return Err(ApiError::bad_request("INVALID_PREKEY_BATCH"));
    }
    let mut tx = state.pool.begin().await?;
    let mut response = Vec::with_capacity(request.devices.len());
    for device in request.devices {
        if !(1..=2).contains(&device.device_id) {
            return Err(ApiError::bad_request("INVALID_DEVICE_ID"));
        }
        let authorized: bool = sqlx::query_scalar(
            "SELECT $1 = $2 OR EXISTS(SELECT 1 FROM memberships mine JOIN memberships theirs ON theirs.channel_id = mine.channel_id WHERE mine.aci = $1 AND theirs.aci = $2 AND mine.left_epoch IS NULL AND theirs.left_epoch IS NULL)",
        )
        .bind(authenticated.aci)
        .bind(device.aci)
        .fetch_one(&mut *tx)
        .await?;
        if !authorized {
            return Err(ApiError::forbidden());
        }
        let bundle: Option<Vec<u8>> = sqlx::query_scalar(
            "SELECT p.opaque_bundle FROM prekey_bundles p JOIN devices d ON d.aci = p.aci AND d.device_id = p.device_id WHERE p.aci = $1 AND p.device_id = $2 AND d.status = 'active'",
        )
        .bind(device.aci)
        .bind(device.device_id)
        .fetch_optional(&mut *tx)
        .await?;
        let Some(bundle) = bundle else { continue };
        let mut one_time_prekeys = Vec::new();
        for kind in ["x25519", "kyber"] {
            let key: Option<(i32, Vec<u8>)> = sqlx::query_as(
                "UPDATE one_time_prekeys SET consumed_at = now() WHERE id = (SELECT id FROM one_time_prekeys WHERE aci = $1 AND device_id = $2 AND kind = $3 AND consumed_at IS NULL ORDER BY id FOR UPDATE SKIP LOCKED LIMIT 1) RETURNING key_id, public_key",
            )
            .bind(device.aci)
            .bind(device.device_id)
            .bind(kind)
            .fetch_optional(&mut *tx)
            .await?;
            if let Some((key_id, public_key)) = key {
                one_time_prekeys.push(OneTimePreKeyResponse {
                    kind: kind.to_owned(),
                    key_id,
                    public_key: URL_SAFE_NO_PAD.encode(public_key),
                });
            }
        }
        response.push(PreKeyBundleResponse {
            aci: device.aci,
            device_id: device.device_id,
            opaque_bundle: URL_SAFE_NO_PAD.encode(bundle),
            one_time_prekeys,
        });
    }
    tx.commit().await?;
    Ok(Json(response))
}

fn validate_mailbox_batch(
    request: &MailboxEnvelopeBatchRequest,
    now: DateTime<Utc>,
) -> Result<Vec<DecodedMailboxRecipient>, ApiError> {
    if request.message_id.is_nil()
        || request.recipients.is_empty()
        || request.recipients.len() > MAX_MAILBOX_BATCH_RECIPIENTS
        || request.expires_at <= now
        || request.expires_at > now + Duration::days(MAX_MAILBOX_TTL_DAYS)
    {
        return Err(ApiError::bad_request("INVALID_ENVELOPE_BATCH"));
    }

    let mut addresses = std::collections::HashSet::with_capacity(request.recipients.len());
    let mut decoded = Vec::with_capacity(request.recipients.len());
    for recipient in &request.recipients {
        if !(1..=2).contains(&recipient.device_id)
            || !addresses.insert((recipient.aci, recipient.device_id))
        {
            return Err(ApiError::bad_request("INVALID_RECIPIENTS"));
        }
        decoded.push(DecodedMailboxRecipient {
            aci: recipient.aci,
            device_id: recipient.device_id,
            envelope: decode_sized(
                &recipient.envelope,
                1,
                MAX_MAILBOX_ENVELOPE_BYTES,
                "INVALID_ENVELOPE",
            )?,
        });
    }
    Ok(decoded)
}

fn validate_push_provider(provider: &str) -> Result<(), ApiError> {
    if matches!(
        provider,
        "fcm" | "apns" | "apns-ptt" | "apns-sandbox" | "apns-ptt-sandbox"
    ) {
        Ok(())
    } else {
        Err(ApiError::bad_request("INVALID_PUSH_PROVIDER"))
    }
}

async fn register_push(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<PushRegistrationRequest>,
) -> Result<Json<AcceptedResponse>, ApiError> {
    let authenticated = require_device(&state.pool, &headers).await?;
    validate_push_provider(&request.provider)?;
    let token = decode_sized(&request.token, 16, 4_096, "INVALID_PUSH_TOKEN")?;
    let owner: Option<(Uuid, i32)> = sqlx::query_as(
        "SELECT aci, device_id FROM push_registrations WHERE provider = $1 AND token = $2",
    )
    .bind(&request.provider)
    .bind(&token)
    .fetch_optional(&state.pool)
    .await?;
    if owner.is_some_and(|owner| owner != (authenticated.aci, authenticated.device_id)) {
        return Err(ApiError::conflict("PUSH_TOKEN_IN_USE"));
    }
    let result = sqlx::query(
        "INSERT INTO push_registrations(aci, device_id, provider, token) VALUES ($1, $2, $3, $4) ON CONFLICT(aci, device_id, provider) DO UPDATE SET token = excluded.token, updated_at = now()",
    )
    .bind(authenticated.aci)
    .bind(authenticated.device_id)
    .bind(&request.provider)
    .bind(token)
    .execute(&state.pool)
    .await;
    if let Err(error) = result {
        if error
            .as_database_error()
            .and_then(sqlx::error::DatabaseError::constraint)
            == Some("push_registrations_provider_token")
        {
            return Err(ApiError::conflict("PUSH_TOKEN_IN_USE"));
        }
        return Err(error.into());
    }
    Ok(Json(AcceptedResponse { accepted: true }))
}

async fn remove_push_registration(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<PushRegistrationRemoveRequest>,
) -> Result<Json<AcceptedResponse>, ApiError> {
    let authenticated = require_device(&state.pool, &headers).await?;
    validate_push_provider(&request.provider)?;
    sqlx::query(
        "DELETE FROM push_registrations WHERE aci = $1 AND device_id = $2 AND provider = $3",
    )
    .bind(authenticated.aci)
    .bind(authenticated.device_id)
    .bind(request.provider)
    .execute(&state.pool)
    .await?;
    Ok(Json(AcceptedResponse { accepted: true }))
}

async fn enqueue_mailbox_envelopes(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<MailboxEnvelopeBatchRequest>,
) -> Result<Json<MailboxEnqueueResponse>, ApiError> {
    let authenticated = require_device(&state.pool, &headers).await?;
    let recipients = validate_mailbox_batch(&request, Utc::now())?;
    let mut tx = state.pool.begin().await?;
    let mut accepted_recipients = 0_u64;

    for recipient in recipients {
        let mailbox_id: Option<Uuid> = sqlx::query_scalar(
            "SELECT d.mailbox_id FROM devices d JOIN accounts a ON a.aci = d.aci WHERE d.aci = $2 AND d.device_id = $3 AND d.status = 'active' AND a.disabled_at IS NULL AND ($1 = $2 OR EXISTS(SELECT 1 FROM memberships mine JOIN memberships theirs ON theirs.channel_id = mine.channel_id WHERE mine.aci = $1 AND theirs.aci = $2 AND mine.left_epoch IS NULL AND theirs.left_epoch IS NULL))",
        )
        .bind(authenticated.aci)
        .bind(recipient.aci)
        .bind(recipient.device_id)
        .fetch_optional(&mut *tx)
        .await?;
        let mailbox_id = mailbox_id.ok_or_else(ApiError::forbidden)?;
        let result = sqlx::query(
            "INSERT INTO mailbox_items(item_id, message_id, mailbox_id, envelope, expires_at) VALUES ($1, $2, $3, $4, $5) ON CONFLICT(mailbox_id, message_id) DO NOTHING",
        )
        .bind(Uuid::new_v4())
        .bind(request.message_id)
        .bind(mailbox_id)
        .bind(recipient.envelope)
        .bind(request.expires_at)
        .execute(&mut *tx)
        .await?;
        accepted_recipients += result.rows_affected();
        if result.rows_affected() == 1 {
            sqlx::query(
                "INSERT INTO push_outbox(id, message_id, aci, device_id, provider) SELECT gen_random_uuid(), $1, $2, $3, provider FROM push_registrations WHERE aci = $2 AND device_id = $3 ON CONFLICT DO NOTHING",
            )
            .bind(request.message_id)
            .bind(recipient.aci)
            .bind(recipient.device_id)
            .execute(&mut *tx)
            .await?;
        }
    }

    tx.commit().await?;
    Ok(Json(MailboxEnqueueResponse {
        accepted_recipients,
    }))
}

async fn poll_mailbox(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<MailboxPollQuery>,
) -> Result<Json<Vec<MailboxItemResponse>>, ApiError> {
    let authenticated = require_device(&state.pool, &headers).await?;
    let limit = query.limit.unwrap_or(100);
    if !(1..=MAX_MAILBOX_POLL_ITEMS).contains(&limit) {
        return Err(ApiError::bad_request("INVALID_MAILBOX_LIMIT"));
    }

    let mut tx = state.pool.begin().await?;
    let mailbox_id: Uuid = sqlx::query_scalar(
        "SELECT mailbox_id FROM devices WHERE aci = $1 AND device_id = $2 AND status = 'active'",
    )
    .bind(authenticated.aci)
    .bind(authenticated.device_id)
    .fetch_one(&mut *tx)
    .await?;
    sqlx::query("DELETE FROM mailbox_items WHERE mailbox_id = $1 AND expires_at <= now()")
        .bind(mailbox_id)
        .execute(&mut *tx)
        .await?;
    let items = sqlx::query_as::<_, MailboxItemRow>(
        "SELECT item_id, message_id, envelope, expires_at, created_at FROM mailbox_items WHERE mailbox_id = $1 AND delivered_at IS NULL AND expires_at > now() ORDER BY created_at, item_id LIMIT $2",
    )
    .bind(mailbox_id)
    .bind(limit)
    .fetch_all(&mut *tx)
    .await?;
    tx.commit().await?;

    Ok(Json(
        items
            .into_iter()
            .map(|item| MailboxItemResponse {
                item_id: item.item_id,
                message_id: item.message_id,
                envelope: URL_SAFE_NO_PAD.encode(item.envelope),
                expires_at: item.expires_at,
                created_at: item.created_at,
            })
            .collect(),
    ))
}

async fn acknowledge_mailbox_items(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<MailboxAckRequest>,
) -> Result<Json<MailboxAckResponse>, ApiError> {
    let authenticated = require_device(&state.pool, &headers).await?;
    if request.item_ids.is_empty() || request.item_ids.len() > MAX_MAILBOX_POLL_ITEMS as usize {
        return Err(ApiError::bad_request("INVALID_MAILBOX_ACK"));
    }
    let unique_ids: std::collections::HashSet<_> = request.item_ids.iter().copied().collect();
    if unique_ids.len() != request.item_ids.len() || unique_ids.contains(&Uuid::nil()) {
        return Err(ApiError::bad_request("INVALID_MAILBOX_ACK"));
    }

    let result = sqlx::query(
        "UPDATE mailbox_items SET delivered_at = now() WHERE mailbox_id = (SELECT mailbox_id FROM devices WHERE aci = $1 AND device_id = $2 AND status = 'active') AND item_id = ANY($3) AND delivered_at IS NULL",
    )
    .bind(authenticated.aci)
    .bind(authenticated.device_id)
    .bind(&request.item_ids)
    .execute(&state.pool)
    .await?;
    Ok(Json(MailboxAckResponse {
        acknowledged: result.rows_affected(),
    }))
}

async fn enqueue_chat(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<ChatBatchRequest>,
) -> Result<Json<MailboxEnqueueResponse>, ApiError> {
    let authenticated = require_device(&state.pool, &headers).await?;
    let now = Utc::now();
    if request.message_id.is_nil()
        || request.channel_id.is_nil()
        || request.membership_epoch <= 0
        || request.recipients.is_empty()
        || request.recipients.len() > MAX_MAILBOX_BATCH_RECIPIENTS
        || request.expires_at <= now
        || request.expires_at > now + Duration::days(MAX_MAILBOX_TTL_DAYS)
    {
        return Err(ApiError::bad_request("INVALID_CHAT_MESSAGE"));
    }
    let current_epoch: Option<i32> = sqlx::query_scalar(
        "SELECT c.membership_epoch FROM channels c JOIN memberships m ON m.channel_id=c.channel_id WHERE c.channel_id=$1 AND m.aci=$2 AND m.left_epoch IS NULL",
    ).bind(request.channel_id).bind(authenticated.aci).fetch_optional(&state.pool).await?;
    if current_epoch.is_none() {
        return Err(ApiError::forbidden());
    }
    if current_epoch != Some(request.membership_epoch) {
        return Err(ApiError::conflict("STALE_MEMBERSHIP_EPOCH"));
    }

    let mut addresses = std::collections::HashSet::with_capacity(request.recipients.len());
    let mut decoded = Vec::with_capacity(request.recipients.len());
    for recipient in &request.recipients {
        if !(1..=2).contains(&recipient.device_id)
            || !addresses.insert((recipient.aci, recipient.device_id))
        {
            return Err(ApiError::bad_request("INVALID_RECIPIENTS"));
        }
        decoded.push((
            recipient.aci,
            recipient.device_id,
            decode_sized(
                &recipient.envelope,
                1,
                MAX_CHAT_ENVELOPE_BYTES,
                "INVALID_ENVELOPE",
            )?,
        ));
    }

    let mut tx = state.pool.begin().await?;
    let mut accepted_recipients = 0_u64;
    for (aci, device_id, envelope) in decoded {
        let allowed: Option<bool> = sqlx::query_scalar(
            "SELECT true FROM devices d JOIN accounts a ON a.aci=d.aci JOIN memberships m ON m.aci=d.aci WHERE d.aci=$1 AND d.device_id=$2 AND d.status='active' AND a.disabled_at IS NULL AND m.channel_id=$3 AND m.left_epoch IS NULL",
        ).bind(aci).bind(device_id).bind(request.channel_id).fetch_optional(&mut *tx).await?;
        if allowed.is_none() {
            return Err(ApiError::forbidden());
        }
        let queued: i64 = sqlx::query_scalar(
            "SELECT count(*) FROM chat_items WHERE recipient_aci=$1 AND recipient_device_id=$2 AND delivered_at IS NULL AND expires_at>now()",
        ).bind(aci).bind(device_id).fetch_one(&mut *tx).await?;
        if queued >= 1_000 {
            return Err(ApiError::too_many_requests());
        }
        let result = sqlx::query(
            "INSERT INTO chat_items(item_id,message_id,channel_id,membership_epoch,recipient_aci,recipient_device_id,envelope,expires_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8) ON CONFLICT(recipient_aci,recipient_device_id,message_id) DO NOTHING",
        ).bind(Uuid::new_v4()).bind(request.message_id).bind(request.channel_id)
            .bind(request.membership_epoch).bind(aci).bind(device_id).bind(envelope)
            .bind(request.expires_at).execute(&mut *tx).await?;
        accepted_recipients += result.rows_affected();
        if result.rows_affected() == 1 {
            sqlx::query(
                "INSERT INTO push_outbox(id,message_id,aci,device_id,provider) SELECT gen_random_uuid(),$1,$2,$3,provider FROM push_registrations WHERE aci=$2 AND device_id=$3 ON CONFLICT DO NOTHING",
            ).bind(request.message_id).bind(aci).bind(device_id).execute(&mut *tx).await?;
        }
    }
    tx.commit().await?;
    Ok(Json(MailboxEnqueueResponse {
        accepted_recipients,
    }))
}

async fn poll_chat(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<ChatPollQuery>,
) -> Result<Json<Vec<ChatItemResponse>>, ApiError> {
    let authenticated = require_device(&state.pool, &headers).await?;
    let limit = query.limit.unwrap_or(100);
    if !(1..=100).contains(&limit) {
        return Err(ApiError::bad_request("INVALID_CHAT_LIMIT"));
    }
    sqlx::query(
        "DELETE FROM chat_items WHERE recipient_aci=$1 AND recipient_device_id=$2 AND expires_at<=now()",
    ).bind(authenticated.aci).bind(authenticated.device_id).execute(&state.pool).await?;
    let rows = sqlx::query_as::<_, ChatItemRow>(
        "SELECT item_id,message_id,channel_id,membership_epoch,envelope FROM chat_items WHERE recipient_aci=$1 AND recipient_device_id=$2 AND delivered_at IS NULL AND expires_at>now() ORDER BY created_at,item_id LIMIT $3",
    ).bind(authenticated.aci).bind(authenticated.device_id).bind(limit).fetch_all(&state.pool).await?;
    Ok(Json(
        rows.into_iter()
            .map(|row| ChatItemResponse {
                item_id: row.item_id,
                message_id: row.message_id,
                channel_id: row.channel_id,
                membership_epoch: row.membership_epoch,
                envelope: URL_SAFE_NO_PAD.encode(row.envelope),
            })
            .collect(),
    ))
}

async fn acknowledge_chat(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<MailboxAckRequest>,
) -> Result<Json<MailboxAckResponse>, ApiError> {
    let authenticated = require_device(&state.pool, &headers).await?;
    if request.item_ids.is_empty() || request.item_ids.len() > 100 {
        return Err(ApiError::bad_request("INVALID_CHAT_ACK"));
    }
    let unique: std::collections::HashSet<_> = request.item_ids.iter().copied().collect();
    if unique.len() != request.item_ids.len() || unique.contains(&Uuid::nil()) {
        return Err(ApiError::bad_request("INVALID_CHAT_ACK"));
    }
    let result = sqlx::query(
        "UPDATE chat_items SET delivered_at=now() WHERE recipient_aci=$1 AND recipient_device_id=$2 AND item_id=ANY($3) AND delivered_at IS NULL",
    ).bind(authenticated.aci).bind(authenticated.device_id).bind(&request.item_ids)
        .execute(&state.pool).await?;
    Ok(Json(MailboxAckResponse {
        acknowledged: result.rows_affected(),
    }))
}

async fn upload_chat_attachment(
    State(state): State<AppState>,
    Path(attachment_id): Path<Uuid>,
    Query(query): Query<ChatAttachmentQuery>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<ChatAttachmentResponse>, ApiError> {
    let authenticated = require_device(&state.pool, &headers).await?;
    if attachment_id.is_nil()
        || query.channel_id.is_nil()
        || query.membership_epoch <= 0
        || body.is_empty()
        || body.len() > MAX_CHAT_ATTACHMENT_BYTES
    {
        return Err(ApiError::bad_request("INVALID_CHAT_ATTACHMENT"));
    }
    let digest_header = headers
        .get("x-ciphertext-sha256")
        .and_then(|value| value.to_str().ok())
        .filter(|value| value.len() == 64)
        .ok_or_else(|| ApiError::bad_request("INVALID_CHAT_ATTACHMENT"))?;
    let declared_digest =
        hex::decode(digest_header).map_err(|_| ApiError::bad_request("INVALID_CHAT_ATTACHMENT"))?;
    let actual_digest = Sha256::digest(&body);
    if declared_digest.as_slice() != actual_digest.as_slice() {
        return Err(ApiError::bad_request("ATTACHMENT_INTEGRITY_MISMATCH"));
    }
    let membership: Option<(i32, i32)> = sqlx::query_as(
        "SELECT c.membership_epoch,c.retention_days FROM channels c JOIN memberships m ON m.channel_id=c.channel_id WHERE c.channel_id=$1 AND m.aci=$2 AND m.left_epoch IS NULL",
    ).bind(query.channel_id).bind(authenticated.aci).fetch_optional(&state.pool).await?;
    let (current_epoch, retention_days) = membership.ok_or_else(ApiError::forbidden)?;
    if current_epoch != query.membership_epoch {
        return Err(ApiError::conflict("STALE_MEMBERSHIP_EPOCH"));
    }
    let existing: Option<(Uuid, i32, Uuid, i16, String, i64, Vec<u8>, DateTime<Utc>)> =
        sqlx::query_as(
            "SELECT channel_id,membership_epoch,uploader_aci,uploader_device_id,storage_key,ciphertext_bytes,ciphertext_sha256,expires_at FROM chat_attachments WHERE attachment_id=$1",
        )
        .bind(attachment_id)
        .fetch_optional(&state.pool)
        .await?;
    if let Some((
        channel_id,
        epoch,
        uploader_aci,
        uploader_device_id,
        storage_key,
        bytes,
        digest,
        expires_at,
    )) = existing
    {
        let same_upload = channel_id == query.channel_id
            && epoch == query.membership_epoch
            && uploader_aci == authenticated.aci
            && i32::from(uploader_device_id) == authenticated.device_id
            && bytes == body.len() as i64
            && digest.as_slice() == actual_digest.as_slice();
        if !same_upload {
            return Err(ApiError::conflict("ATTACHMENT_ID_REUSED"));
        }
        let maximum = usize::try_from(bytes)
            .ok()
            .filter(|size| *size <= MAX_CHAT_ATTACHMENT_BYTES)
            .ok_or_else(|| ApiError::unavailable("ATTACHMENT_UNAVAILABLE"))?;
        let stored = state.object_store.get(&storage_key, maximum).await?;
        if stored.len() != maximum || Sha256::digest(&stored).as_slice() != digest.as_slice() {
            return Err(ApiError::unavailable("ATTACHMENT_UNAVAILABLE"));
        }
        return Ok(Json(ChatAttachmentResponse {
            attachment_id,
            ciphertext_bytes: bytes,
            ciphertext_sha256: hex::encode(digest),
            expires_at,
        }));
    }
    let storage_key = format!("chat/{}/{attachment_id}.bin", query.channel_id);
    let expires_at = Utc::now() + Duration::days(retention_days as i64);
    let result = sqlx::query(
        "INSERT INTO chat_attachments(attachment_id,channel_id,membership_epoch,uploader_aci,uploader_device_id,storage_key,ciphertext_bytes,ciphertext_sha256,expires_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9)",
    ).bind(attachment_id).bind(query.channel_id).bind(query.membership_epoch)
        .bind(authenticated.aci).bind(authenticated.device_id).bind(&storage_key)
        .bind(body.len() as i64).bind(actual_digest.as_slice()).bind(expires_at)
        .execute(&state.pool).await;
    if let Err(error) = result {
        return Err(error.into());
    }
    if let Err(error) = state.object_store.put(&storage_key, body.to_vec()).await {
        let _ = sqlx::query("DELETE FROM chat_attachments WHERE attachment_id=$1")
            .bind(attachment_id)
            .execute(&state.pool)
            .await;
        return Err(error.into());
    }
    Ok(Json(ChatAttachmentResponse {
        attachment_id,
        ciphertext_bytes: body.len() as i64,
        ciphertext_sha256: hex::encode(actual_digest),
        expires_at,
    }))
}

async fn create_chat_attachment_upload(
    State(state): State<AppState>,
    Path(attachment_id): Path<Uuid>,
    headers: HeaderMap,
    Json(request): Json<ChatAttachmentUploadRequest>,
) -> Result<Json<ChatAttachmentUploadResponse>, ApiError> {
    let authenticated = require_device(&state.pool, &headers).await?;
    let digest = hex::decode(&request.ciphertext_sha256)
        .ok()
        .filter(|value| value.len() == 32)
        .ok_or_else(|| ApiError::bad_request("INVALID_CHAT_ATTACHMENT"))?;
    if attachment_id.is_nil()
        || request.channel_id.is_nil()
        || request.membership_epoch <= 0
        || !(1..=MAX_CHAT_ATTACHMENT_BYTES as i64).contains(&request.ciphertext_bytes)
    {
        return Err(ApiError::bad_request("INVALID_CHAT_ATTACHMENT"));
    }
    let membership: Option<(i32, i32)> = sqlx::query_as(
        "SELECT c.membership_epoch,c.retention_days FROM channels c JOIN memberships m ON m.channel_id=c.channel_id WHERE c.channel_id=$1 AND m.aci=$2 AND m.left_epoch IS NULL",
    )
    .bind(request.channel_id)
    .bind(authenticated.aci)
    .fetch_optional(&state.pool)
    .await?;
    let (current_epoch, _) = membership.ok_or_else(ApiError::forbidden)?;
    if current_epoch != request.membership_epoch {
        return Err(ApiError::conflict("MEMBERSHIP_EPOCH_MISMATCH"));
    }
    let complete: Option<(Uuid, i32, Uuid, i16, String, i64, Vec<u8>, DateTime<Utc>)> =
        sqlx::query_as(
            "SELECT channel_id,membership_epoch,uploader_aci,uploader_device_id,storage_key,ciphertext_bytes,ciphertext_sha256,expires_at FROM chat_attachments WHERE attachment_id=$1",
        )
        .bind(attachment_id)
        .fetch_optional(&state.pool)
        .await?;
    if let Some((channel_id, epoch, aci, device_id, key, bytes, stored_digest, expires_at)) =
        complete
    {
        if channel_id != request.channel_id
            || epoch != request.membership_epoch
            || aci != authenticated.aci
            || i32::from(device_id) != authenticated.device_id
            || bytes != request.ciphertext_bytes
            || stored_digest != digest
        {
            return Err(ApiError::conflict("ATTACHMENT_ID_REUSED"));
        }
        let object = state
            .object_store
            .get(&key, MAX_CHAT_ATTACHMENT_BYTES)
            .await?;
        if object.len() as i64 != bytes || Sha256::digest(&object).as_slice() != stored_digest {
            return Err(ApiError::unavailable("ATTACHMENT_UNAVAILABLE"));
        }
        return Ok(Json(ChatAttachmentUploadResponse {
            state: "complete",
            attachment_id,
            upload_id: None,
            ciphertext_bytes: bytes,
            ciphertext_sha256: hex::encode(stored_digest),
            part_size: None,
            uploaded_parts: Vec::new(),
            expires_at,
        }));
    }
    let existing = sqlx::query_as::<_, ChatAttachmentUploadRow>(
        "SELECT upload_id,attachment_id,channel_id,membership_epoch,uploader_aci,uploader_device_id,storage_key,ciphertext_bytes,ciphertext_sha256,part_size,expires_at FROM chat_attachment_uploads WHERE attachment_id=$1",
    )
    .bind(attachment_id)
    .fetch_optional(&state.pool)
    .await?;
    if let Some(upload) = existing {
        if upload.channel_id != request.channel_id
            || upload.membership_epoch != request.membership_epoch
            || upload.uploader_aci != authenticated.aci
            || upload.uploader_device_id != authenticated.device_id
            || upload.ciphertext_bytes != request.ciphertext_bytes
            || upload.ciphertext_sha256 != digest
        {
            return Err(ApiError::conflict("ATTACHMENT_ID_REUSED"));
        }
        if upload.expires_at <= Utc::now() {
            return Err(ApiError::gone("UPLOAD_EXPIRED"));
        }
        return Ok(Json(
            chat_attachment_upload_state(&state.pool, upload).await?,
        ));
    }
    let upload_id = Uuid::new_v4();
    let expires_at = Utc::now() + Duration::hours(24);
    let storage_key = format!("chat/{}/{attachment_id}.bin", request.channel_id);
    sqlx::query(
        "INSERT INTO chat_attachment_uploads(upload_id,attachment_id,channel_id,membership_epoch,uploader_aci,uploader_device_id,storage_key,ciphertext_bytes,ciphertext_sha256,part_size,expires_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)",
    )
    .bind(upload_id).bind(attachment_id).bind(request.channel_id).bind(request.membership_epoch)
    .bind(authenticated.aci).bind(authenticated.device_id).bind(&storage_key)
    .bind(request.ciphertext_bytes).bind(&digest).bind(CHAT_ATTACHMENT_PART_BYTES as i32)
    .bind(expires_at).execute(&state.pool).await?;
    Ok(Json(ChatAttachmentUploadResponse {
        state: "uploading",
        attachment_id,
        upload_id: Some(upload_id),
        ciphertext_bytes: request.ciphertext_bytes,
        ciphertext_sha256: hex::encode(digest),
        part_size: Some(CHAT_ATTACHMENT_PART_BYTES),
        uploaded_parts: Vec::new(),
        expires_at,
    }))
}

async fn upload_chat_attachment_part(
    State(state): State<AppState>,
    Path((attachment_id, upload_id, part_number)): Path<(Uuid, Uuid, i32)>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<ChatAttachmentPartStoredResponse>, ApiError> {
    let authenticated = require_device(&state.pool, &headers).await?;
    let upload =
        require_chat_attachment_upload(&state.pool, attachment_id, upload_id, &authenticated)
            .await?;
    let part_count =
        (upload.ciphertext_bytes + i64::from(upload.part_size) - 1) / i64::from(upload.part_size);
    if part_number < 1 || i64::from(part_number) > part_count {
        return Err(ApiError::bad_request("INVALID_UPLOAD_PART"));
    }
    let expected = if i64::from(part_number) == part_count {
        upload.ciphertext_bytes - i64::from(upload.part_size) * (part_count - 1)
    } else {
        i64::from(upload.part_size)
    };
    let declared_digest = headers
        .get("x-ciphertext-sha256")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| hex::decode(value).ok())
        .filter(|value| value.len() == 32)
        .ok_or_else(|| ApiError::bad_request("INVALID_UPLOAD_PART"))?;
    let actual_digest = Sha256::digest(&body);
    if body.len() as i64 != expected || actual_digest.as_slice() != declared_digest {
        return Err(ApiError::bad_request("UPLOAD_PART_INTEGRITY_FAILED"));
    }
    let existing: Option<(String, i32, Vec<u8>)> = sqlx::query_as(
        "SELECT storage_key,ciphertext_bytes,ciphertext_sha256 FROM chat_attachment_upload_parts WHERE upload_id=$1 AND part_number=$2",
    ).bind(upload_id).bind(part_number).fetch_optional(&state.pool).await?;
    if let Some((key, bytes, digest)) = existing {
        if i64::from(bytes) != expected || digest.as_slice() != actual_digest.as_slice() {
            return Err(ApiError::conflict("UPLOAD_PART_REUSED"));
        }
        let stored = state
            .object_store
            .get(&key, CHAT_ATTACHMENT_PART_BYTES)
            .await?;
        if stored.len() as i64 != expected || Sha256::digest(&stored).as_slice() != digest {
            return Err(ApiError::unavailable("UPLOAD_PART_UNAVAILABLE"));
        }
        return Ok(Json(ChatAttachmentPartStoredResponse {
            upload_id,
            part_number,
            ciphertext_bytes: bytes,
            ciphertext_sha256: hex::encode(digest),
        }));
    }
    let storage_key = format!("chat-parts/{upload_id}/{part_number}.bin");
    state.object_store.put(&storage_key, body.to_vec()).await?;
    let inserted = sqlx::query(
        "INSERT INTO chat_attachment_upload_parts(upload_id,part_number,storage_key,ciphertext_bytes,ciphertext_sha256) VALUES($1,$2,$3,$4,$5)",
    ).bind(upload_id).bind(part_number).bind(&storage_key).bind(body.len() as i32)
        .bind(actual_digest.as_slice()).execute(&state.pool).await;
    if let Err(error) = inserted {
        let _ = state.object_store.delete(&storage_key).await;
        return Err(error.into());
    }
    Ok(Json(ChatAttachmentPartStoredResponse {
        upload_id,
        part_number,
        ciphertext_bytes: body.len() as i32,
        ciphertext_sha256: hex::encode(actual_digest),
    }))
}

async fn complete_chat_attachment_upload(
    State(state): State<AppState>,
    Path((attachment_id, upload_id)): Path<(Uuid, Uuid)>,
    headers: HeaderMap,
) -> Result<Json<ChatAttachmentUploadResponse>, ApiError> {
    let authenticated = require_device(&state.pool, &headers).await?;
    let upload =
        require_chat_attachment_upload(&state.pool, attachment_id, upload_id, &authenticated)
            .await?;
    let membership: Option<(i32, i32)> = sqlx::query_as(
        "SELECT c.membership_epoch,c.retention_days FROM channels c JOIN memberships m ON m.channel_id=c.channel_id WHERE c.channel_id=$1 AND m.aci=$2 AND m.left_epoch IS NULL",
    ).bind(upload.channel_id).bind(authenticated.aci).fetch_optional(&state.pool).await?;
    let (epoch, retention_days) = membership.ok_or_else(ApiError::forbidden)?;
    if epoch != upload.membership_epoch {
        return Err(ApiError::conflict("MEMBERSHIP_EPOCH_MISMATCH"));
    }
    let parts = sqlx::query_as::<_, ChatAttachmentUploadPartRow>(
        "SELECT part_number,storage_key,ciphertext_bytes,ciphertext_sha256 FROM chat_attachment_upload_parts WHERE upload_id=$1 ORDER BY part_number",
    ).bind(upload_id).fetch_all(&state.pool).await?;
    let expected_parts =
        (upload.ciphertext_bytes + i64::from(upload.part_size) - 1) / i64::from(upload.part_size);
    if parts.len() as i64 != expected_parts
        || parts
            .iter()
            .enumerate()
            .any(|(index, part)| part.part_number != index as i32 + 1)
    {
        return Err(ApiError::conflict("UPLOAD_INCOMPLETE"));
    }
    let mut ciphertext = Vec::with_capacity(upload.ciphertext_bytes as usize);
    for part in &parts {
        let bytes = state
            .object_store
            .get(&part.storage_key, CHAT_ATTACHMENT_PART_BYTES)
            .await?;
        if bytes.len() != part.ciphertext_bytes as usize
            || Sha256::digest(&bytes).as_slice() != part.ciphertext_sha256
        {
            return Err(ApiError::unavailable("UPLOAD_PART_INTEGRITY_FAILED"));
        }
        ciphertext.extend_from_slice(&bytes);
    }
    if ciphertext.len() as i64 != upload.ciphertext_bytes
        || Sha256::digest(&ciphertext).as_slice() != upload.ciphertext_sha256
    {
        return Err(ApiError::bad_request("ATTACHMENT_INTEGRITY_FAILED"));
    }
    state
        .object_store
        .put(&upload.storage_key, ciphertext)
        .await?;
    let expires_at = Utc::now() + Duration::days(retention_days as i64);
    let inserted = sqlx::query(
        "INSERT INTO chat_attachments(attachment_id,channel_id,membership_epoch,uploader_aci,uploader_device_id,storage_key,ciphertext_bytes,ciphertext_sha256,expires_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9) ON CONFLICT(attachment_id) DO NOTHING",
    ).bind(attachment_id).bind(upload.channel_id).bind(upload.membership_epoch)
        .bind(authenticated.aci).bind(authenticated.device_id).bind(&upload.storage_key)
        .bind(upload.ciphertext_bytes).bind(&upload.ciphertext_sha256).bind(expires_at)
        .execute(&state.pool).await?;
    if inserted.rows_affected() == 0 {
        let existing: Option<(i64, Vec<u8>)> = sqlx::query_as(
            "SELECT ciphertext_bytes,ciphertext_sha256 FROM chat_attachments WHERE attachment_id=$1",
        ).bind(attachment_id).fetch_optional(&state.pool).await?;
        if existing.as_ref().is_none_or(|(bytes, digest)| {
            *bytes != upload.ciphertext_bytes || *digest != upload.ciphertext_sha256
        }) {
            return Err(ApiError::conflict("ATTACHMENT_ID_REUSED"));
        }
    }
    for part in &parts {
        state.object_store.delete(&part.storage_key).await?;
    }
    sqlx::query("DELETE FROM chat_attachment_uploads WHERE upload_id=$1")
        .bind(upload_id)
        .execute(&state.pool)
        .await?;
    Ok(Json(ChatAttachmentUploadResponse {
        state: "complete",
        attachment_id,
        upload_id: None,
        ciphertext_bytes: upload.ciphertext_bytes,
        ciphertext_sha256: hex::encode(upload.ciphertext_sha256),
        part_size: None,
        uploaded_parts: Vec::new(),
        expires_at,
    }))
}

async fn cancel_chat_attachment_upload(
    State(state): State<AppState>,
    Path((attachment_id, upload_id)): Path<(Uuid, Uuid)>,
    headers: HeaderMap,
) -> Result<Json<ChatAttachmentCancelResponse>, ApiError> {
    let authenticated = require_device(&state.pool, &headers).await?;
    let upload =
        require_chat_attachment_upload(&state.pool, attachment_id, upload_id, &authenticated)
            .await?;
    let parts: Vec<String> = sqlx::query_scalar(
        "SELECT storage_key FROM chat_attachment_upload_parts WHERE upload_id=$1",
    )
    .bind(upload_id)
    .fetch_all(&state.pool)
    .await?;
    for key in parts {
        state.object_store.delete(&key).await?;
    }
    sqlx::query("DELETE FROM chat_attachment_uploads WHERE upload_id=$1")
        .bind(upload.upload_id)
        .execute(&state.pool)
        .await?;
    Ok(Json(ChatAttachmentCancelResponse {
        cancelled: true,
        attachment_id,
        upload_id,
    }))
}

async fn require_chat_attachment_upload(
    pool: &PgPool,
    attachment_id: Uuid,
    upload_id: Uuid,
    authenticated: &AuthenticatedDevice,
) -> Result<ChatAttachmentUploadRow, ApiError> {
    if attachment_id.is_nil() || upload_id.is_nil() {
        return Err(ApiError::bad_request("INVALID_UPLOAD_ID"));
    }
    let upload = sqlx::query_as::<_, ChatAttachmentUploadRow>(
        "SELECT upload_id,attachment_id,channel_id,membership_epoch,uploader_aci,uploader_device_id,storage_key,ciphertext_bytes,ciphertext_sha256,part_size,expires_at FROM chat_attachment_uploads WHERE upload_id=$1 AND attachment_id=$2",
    ).bind(upload_id).bind(attachment_id).fetch_optional(pool).await?
        .ok_or_else(|| ApiError::not_found("UPLOAD_NOT_FOUND"))?;
    if upload.uploader_aci != authenticated.aci
        || upload.uploader_device_id != authenticated.device_id
    {
        return Err(ApiError::forbidden());
    }
    if upload.expires_at <= Utc::now() {
        return Err(ApiError::gone("UPLOAD_EXPIRED"));
    }
    Ok(upload)
}

async fn chat_attachment_upload_state(
    pool: &PgPool,
    upload: ChatAttachmentUploadRow,
) -> Result<ChatAttachmentUploadResponse, ApiError> {
    let parts = sqlx::query_as::<_, ChatAttachmentUploadPartRow>(
        "SELECT part_number,storage_key,ciphertext_bytes,ciphertext_sha256 FROM chat_attachment_upload_parts WHERE upload_id=$1 ORDER BY part_number",
    ).bind(upload.upload_id).fetch_all(pool).await?;
    Ok(ChatAttachmentUploadResponse {
        state: "uploading",
        attachment_id: upload.attachment_id,
        upload_id: Some(upload.upload_id),
        ciphertext_bytes: upload.ciphertext_bytes,
        ciphertext_sha256: hex::encode(upload.ciphertext_sha256),
        part_size: Some(upload.part_size as usize),
        uploaded_parts: parts
            .into_iter()
            .map(|part| ChatAttachmentUploadPartResponse {
                part_number: part.part_number,
                ciphertext_bytes: part.ciphertext_bytes,
                ciphertext_sha256: hex::encode(part.ciphertext_sha256),
            })
            .collect(),
        expires_at: upload.expires_at,
    })
}

async fn download_chat_attachment(
    State(state): State<AppState>,
    Path(attachment_id): Path<Uuid>,
    headers: HeaderMap,
) -> Result<axum::response::Response, ApiError> {
    let authenticated = require_device(&state.pool, &headers).await?;
    let row: Option<(String, i64, Vec<u8>)> = sqlx::query_as(
        "SELECT x.storage_key,x.ciphertext_bytes,x.ciphertext_sha256 FROM chat_attachments x JOIN memberships m ON m.channel_id=x.channel_id AND m.aci=$2 JOIN devices d ON d.aci=$2 AND d.device_id=$3 WHERE x.attachment_id=$1 AND x.expires_at>now() AND m.left_epoch IS NULL AND m.joined_epoch<=x.membership_epoch AND d.status='active' AND d.linked_at<=x.created_at",
    ).bind(attachment_id).bind(authenticated.aci).bind(authenticated.device_id)
        .fetch_optional(&state.pool).await?;
    let (storage_key, size, digest) =
        row.ok_or_else(|| ApiError::not_found("ATTACHMENT_NOT_FOUND"))?;
    let total =
        usize::try_from(size).map_err(|_| ApiError::unavailable("ATTACHMENT_UNAVAILABLE"))?;
    let requested_range = parse_http_byte_range(headers.get(header::RANGE), total)?;
    let bytes = if let Some((start, end)) = requested_range {
        state
            .object_store
            .get_range(&storage_key, start, end - start + 1)
            .await?
    } else {
        state
            .object_store
            .get(&storage_key, MAX_CHAT_ATTACHMENT_BYTES)
            .await?
    };
    if requested_range.is_none()
        && (bytes.len() != total || Sha256::digest(&bytes).as_slice() != digest.as_slice())
    {
        return Err(ApiError::unavailable("ATTACHMENT_INTEGRITY_FAILED"));
    }
    let mut response_headers = HeaderMap::new();
    response_headers.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("application/octet-stream"),
    );
    response_headers.insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("private, no-store"),
    );
    response_headers.insert(
        HeaderName::from_static("x-ciphertext-sha256"),
        HeaderValue::from_str(&hex::encode(digest)).map_err(|_| ApiError::internal())?,
    );
    response_headers.insert(header::ACCEPT_RANGES, HeaderValue::from_static("bytes"));
    let status = if let Some((start, end)) = requested_range {
        response_headers.insert(
            header::CONTENT_RANGE,
            HeaderValue::from_str(&format!("bytes {start}-{end}/{total}"))
                .map_err(|_| ApiError::internal())?,
        );
        StatusCode::PARTIAL_CONTENT
    } else {
        StatusCode::OK
    };
    Ok((status, response_headers, bytes).into_response())
}

fn parse_http_byte_range(
    value: Option<&HeaderValue>,
    total: usize,
) -> Result<Option<(usize, usize)>, ApiError> {
    let Some(value) = value else { return Ok(None) };
    let value = value.to_str().map_err(|_| ApiError::invalid_range())?;
    let suffix = value
        .strip_prefix("bytes=")
        .ok_or_else(ApiError::invalid_range)?;
    if suffix.contains(',') {
        return Err(ApiError::invalid_range());
    }
    let (start, end) = suffix.split_once('-').ok_or_else(ApiError::invalid_range)?;
    let start = start
        .parse::<usize>()
        .map_err(|_| ApiError::invalid_range())?;
    let end = if end.is_empty() {
        total.checked_sub(1).ok_or_else(ApiError::invalid_range)?
    } else {
        end.parse::<usize>()
            .map_err(|_| ApiError::invalid_range())?
            .min(total.saturating_sub(1))
    };
    if start >= total || end < start {
        return Err(ApiError::invalid_range());
    }
    Ok(Some((start, end)))
}

fn validate_history_upload(
    request: &HistoryUploadRequest,
    now: DateTime<Utc>,
) -> Result<(u64, Vec<u8>, [u8; 32]), ApiError> {
    if request.talk_id.is_nil()
        || request.channel_id.is_nil()
        || request.membership_epoch <= 0
        || !(1..=MAX_HISTORY_DURATION_MS).contains(&request.duration_ms)
        || request.started_at < now - Duration::days(30)
        || request.started_at > now + Duration::minutes(5)
        || request.ciphertext.len() > MAX_HISTORY_CIPHERTEXT_BYTES * 4 / 3 + 8
    {
        return Err(ApiError::bad_request("INVALID_HISTORY_OBJECT"));
    }
    let media_kid = request
        .media_kid
        .parse::<u64>()
        .ok()
        .filter(|value| *value != 0)
        .ok_or_else(|| ApiError::bad_request("INVALID_MEDIA_KID"))?;
    let ciphertext = decode_sized(
        &request.ciphertext,
        1,
        MAX_HISTORY_CIPHERTEXT_BYTES,
        "INVALID_HISTORY_CIPHERTEXT",
    )?;
    let ciphertext_sha256 = Sha256::digest(&ciphertext).into();
    Ok((media_kid, ciphertext, ciphertext_sha256))
}

fn history_metadata(row: &HistoryObjectRow) -> HistoryMetadataResponse {
    HistoryMetadataResponse {
        object_id: row.object_id,
        talk_id: row.talk_id,
        channel_id: row.channel_id,
        membership_epoch: row.membership_epoch,
        media_kid: row.media_kid.clone(),
        started_at: row.started_at,
        duration_ms: row.duration_ms,
        expires_at: row.expires_at,
        ciphertext_bytes: row.ciphertext_bytes,
    }
}

async fn upload_history_object(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<HistoryUploadRequest>,
) -> Result<Json<HistoryMetadataResponse>, ApiError> {
    let authenticated = require_device(&state.pool, &headers).await?;
    let (media_kid, ciphertext, ciphertext_sha256) = validate_history_upload(&request, Utc::now())?;
    let membership: Option<(i32, String, i32)> = sqlx::query_as(
        "SELECT c.membership_epoch, m.role, c.retention_days FROM channels c JOIN memberships m ON m.channel_id = c.channel_id WHERE c.channel_id = $1 AND m.aci = $2 AND m.left_epoch IS NULL",
    )
    .bind(request.channel_id)
    .bind(authenticated.aci)
    .fetch_optional(&state.pool)
    .await?;
    let (current_epoch, role, retention_days) = membership.ok_or_else(ApiError::forbidden)?;
    if role == "listen" {
        return Err(ApiError::forbidden());
    }
    if request.membership_epoch != current_epoch {
        return Err(ApiError::conflict("STALE_MEMBERSHIP_EPOCH"));
    }

    let existing = fetch_history_by_talk(&state.pool, request.channel_id, request.talk_id).await?;
    if let Some(existing) = existing {
        if existing.ciphertext_sha256.as_deref() == Some(ciphertext_sha256.as_slice()) {
            return Ok(Json(history_metadata(&existing)));
        }
        return Err(ApiError::conflict("TALK_ID_REUSED"));
    }

    let object_id = Uuid::new_v4();
    let storage_key = format!("history/{}/{object_id}.bin", request.channel_id);
    let ciphertext_bytes = ciphertext.len() as i64;
    state.object_store.put(&storage_key, ciphertext).await?;
    let expires_at = Utc::now() + Duration::days(retention_days as i64);
    let inserted = sqlx::query_as::<_, HistoryObjectRow>(
        "INSERT INTO history_objects(object_id, channel_id, talk_id, membership_epoch, media_kid, storage_key, ciphertext_bytes, expires_at, started_at, duration_ms, ciphertext_sha256) VALUES ($1, $2, $3, $4, $5::numeric, $6, $7, $8, $9, $10, $11) ON CONFLICT DO NOTHING RETURNING object_id, talk_id, channel_id, membership_epoch, media_kid::text AS media_kid, started_at, duration_ms, expires_at, storage_key, ciphertext_bytes, ciphertext_sha256",
    )
    .bind(object_id)
    .bind(request.channel_id)
    .bind(request.talk_id)
    .bind(request.membership_epoch)
    .bind(media_kid.to_string())
    .bind(&storage_key)
    .bind(ciphertext_bytes)
    .bind(expires_at)
    .bind(request.started_at)
    .bind(request.duration_ms as i32)
    .bind(ciphertext_sha256.as_slice())
    .fetch_optional(&state.pool)
    .await;

    match inserted {
        Ok(Some(row)) => Ok(Json(history_metadata(&row))),
        Ok(None) => {
            let _ = state.object_store.delete(&storage_key).await;
            let existing = fetch_history_by_talk(&state.pool, request.channel_id, request.talk_id)
                .await?
                .ok_or_else(ApiError::internal)?;
            if existing.ciphertext_sha256.as_deref() == Some(ciphertext_sha256.as_slice()) {
                Ok(Json(history_metadata(&existing)))
            } else {
                Err(ApiError::conflict("TALK_ID_REUSED"))
            }
        }
        Err(error) => {
            let _ = state.object_store.delete(&storage_key).await;
            Err(error.into())
        }
    }
}

async fn fetch_history_by_talk(
    pool: &PgPool,
    channel_id: Uuid,
    talk_id: Uuid,
) -> Result<Option<HistoryObjectRow>, ApiError> {
    Ok(sqlx::query_as::<_, HistoryObjectRow>(
        "SELECT object_id, talk_id, channel_id, membership_epoch, media_kid::text AS media_kid, started_at, duration_ms, expires_at, storage_key, ciphertext_bytes, ciphertext_sha256 FROM history_objects WHERE channel_id = $1 AND talk_id = $2",
    )
    .bind(channel_id)
    .bind(talk_id)
    .fetch_optional(pool)
    .await?)
}

async fn list_history_objects(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<HistoryListQuery>,
) -> Result<Json<Vec<HistoryMetadataResponse>>, ApiError> {
    let authenticated = require_device(&state.pool, &headers).await?;
    let limit = query.limit.unwrap_or(100);
    if query.channel_id.is_nil() || !(1..=MAX_HISTORY_LIST_ITEMS).contains(&limit) {
        return Err(ApiError::bad_request("INVALID_HISTORY_QUERY"));
    }
    let rows = sqlx::query_as::<_, HistoryObjectRow>(
        "SELECT h.object_id, h.talk_id, h.channel_id, h.membership_epoch, h.media_kid::text AS media_kid, h.started_at, h.duration_ms, h.expires_at, h.storage_key, h.ciphertext_bytes, h.ciphertext_sha256 FROM history_objects h JOIN memberships m ON m.channel_id = h.channel_id JOIN devices d ON d.aci = m.aci AND d.device_id = $3 WHERE h.channel_id = $1 AND m.aci = $2 AND m.left_epoch IS NULL AND d.status = 'active' AND h.membership_epoch >= m.joined_epoch AND h.created_at >= d.linked_at AND h.expires_at > now() ORDER BY h.created_at DESC, h.object_id LIMIT $4",
    )
    .bind(query.channel_id)
    .bind(authenticated.aci)
    .bind(authenticated.device_id)
    .bind(limit)
    .fetch_all(&state.pool)
    .await?;
    Ok(Json(rows.iter().map(history_metadata).collect()))
}

async fn download_history_object(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(object_id): Path<Uuid>,
) -> Result<Json<HistoryDownloadResponse>, ApiError> {
    let authenticated = require_device(&state.pool, &headers).await?;
    if object_id.is_nil() {
        return Err(ApiError::bad_request("INVALID_HISTORY_OBJECT"));
    }
    let row = sqlx::query_as::<_, HistoryObjectRow>(
        "SELECT h.object_id, h.talk_id, h.channel_id, h.membership_epoch, h.media_kid::text AS media_kid, h.started_at, h.duration_ms, h.expires_at, h.storage_key, h.ciphertext_bytes, h.ciphertext_sha256 FROM history_objects h JOIN memberships m ON m.channel_id = h.channel_id JOIN devices d ON d.aci = m.aci AND d.device_id = $3 WHERE h.object_id = $1 AND m.aci = $2 AND m.left_epoch IS NULL AND d.status = 'active' AND h.membership_epoch >= m.joined_epoch AND h.created_at >= d.linked_at AND h.expires_at > now()",
    )
    .bind(object_id)
    .bind(authenticated.aci)
    .bind(authenticated.device_id)
    .fetch_optional(&state.pool)
    .await?
    .ok_or_else(ApiError::forbidden)?;
    let maximum = usize::try_from(row.ciphertext_bytes)
        .ok()
        .filter(|size| *size <= MAX_HISTORY_CIPHERTEXT_BYTES)
        .ok_or_else(ApiError::internal)?;
    let ciphertext = state.object_store.get(&row.storage_key, maximum).await?;
    let actual_hash: [u8; 32] = Sha256::digest(&ciphertext).into();
    if row.ciphertext_sha256.as_deref() != Some(actual_hash.as_slice()) {
        tracing::error!(object_id = %row.object_id, "history ciphertext integrity check failed");
        return Err(ApiError::internal());
    }
    Ok(Json(HistoryDownloadResponse {
        metadata: history_metadata(&row),
        ciphertext: URL_SAFE_NO_PAD.encode(ciphertext),
    }))
}

async fn relay_credentials(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<RelayCredentialRequest>,
) -> Result<Json<RelayCredentialResponse>, ApiError> {
    let authenticated = require_device(&state.pool, &headers).await?;
    let membership_epoch: Option<i32> = sqlx::query_scalar(
        "SELECT c.membership_epoch FROM channels c JOIN memberships m ON m.channel_id = c.channel_id WHERE c.channel_id = $1 AND m.aci = $2 AND m.left_epoch IS NULL",
    )
    .bind(request.channel_id)
    .bind(authenticated.aci)
    .fetch_optional(&state.pool)
    .await?;
    if membership_epoch.is_none() {
        return Err(ApiError::forbidden());
    }

    let sender_demux = loop {
        let value = rand::rng().random::<u32>();
        if value != 0 {
            break value;
        }
    };
    let now = Utc::now();
    let (ticket, claims) = issue_relay_ticket(
        &state.relay_signing_key,
        request.channel_id,
        authenticated.aci,
        authenticated.device_id as u32,
        sender_demux,
        now,
    )
    .map_err(|_| ApiError::internal())?;
    let expires_at =
        chrono::DateTime::from_timestamp(claims.expires_unix, 0).ok_or_else(ApiError::internal)?;
    sqlx::query(
        "INSERT INTO relay_leases(channel_id, sender_demux, aci, device_id, expires_at, demux_token) VALUES ($1, $2, $3, $4, $5, $6) ON CONFLICT(channel_id, aci, device_id) DO UPDATE SET sender_demux = excluded.sender_demux, expires_at = excluded.expires_at, demux_token = excluded.demux_token",
    )
    .bind(request.channel_id)
    .bind(sender_demux as i64)
    .bind(authenticated.aci)
    .bind(authenticated.device_id)
    .bind(expires_at)
    .bind(claims.demux_token.as_slice())
    .execute(&state.pool)
    .await?;
    Ok(Json(RelayCredentialResponse {
        relay_address: state.relay_public_address.to_string(),
        ticket,
        demux_token: URL_SAFE_NO_PAD.encode(claims.demux_token),
        sender_demux,
        expires_at,
    }))
}

async fn request_floor(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<FloorRequestBody>,
) -> Result<Json<FloorResponse>, ApiError> {
    let authenticated = require_device(&state.pool, &headers).await?;
    if request.sender_demux == 0 {
        return Err(ApiError::bad_request("INVALID_SENDER_DEMUX"));
    }
    let token = decode_sized(&request.request_token, 16, 16, "INVALID_REQUEST_TOKEN")?;
    let token = URL_SAFE_NO_PAD.encode(token);
    let membership: Option<(i32, String, bool)> = sqlx::query_as(
        "SELECT c.membership_epoch, m.role, EXISTS(SELECT 1 FROM relay_leases l WHERE l.channel_id=c.channel_id AND l.aci=m.aci AND l.device_id=$3 AND l.sender_demux=$4 AND l.expires_at > now()) FROM channels c JOIN memberships m ON m.channel_id = c.channel_id WHERE c.channel_id = $1 AND m.aci = $2 AND m.left_epoch IS NULL",
    )
    .bind(request.channel_id)
    .bind(authenticated.aci)
    .bind(authenticated.device_id)
    .bind(i64::from(request.sender_demux))
    .fetch_optional(&state.pool)
    .await?;
    let (membership_epoch, role, relay_authorized) = membership.ok_or_else(ApiError::forbidden)?;
    if !relay_authorized {
        return Err(ApiError::forbidden_code("RELAY_LEASE_REQUIRED"));
    }
    if membership_epoch != request.membership_epoch {
        return Err(ApiError::conflict("STALE_MEMBERSHIP_EPOCH"));
    }
    if role == "listen" {
        return Err(ApiError::forbidden());
    }
    let priority = if request.sos {
        3
    } else {
        match role.as_str() {
            "dispatch" => 2,
            "barge" => 1,
            _ => 0,
        }
    };
    let granted_tot_ms = request.requested_tot_ms.clamp(1_000, 30_000);
    let owner = format!("{}:{}", authenticated.aci, authenticated.device_id);
    let key = format!("ptt:v1:floor:{}", request.channel_id);
    let script = redis::Script::new(
        r#"
        if redis.call('EXISTS', KEYS[1]) == 1 then
          local current_owner = redis.call('HGET', KEYS[1], 'owner')
          local current_token = redis.call('HGET', KEYS[1], 'token')
          local current_priority = tonumber(redis.call('HGET', KEYS[1], 'priority'))
          if current_owner == ARGV[1] and current_token == ARGV[2] then
            return {2, tonumber(redis.call('HGET', KEYS[1], 'tot')), current_priority}
          end
          if tonumber(ARGV[3]) <= current_priority then
            return {0, 0, current_priority}
          end
        end
        redis.call('HSET', KEYS[1], 'owner', ARGV[1], 'token', ARGV[2], 'priority', ARGV[3], 'demux', ARGV[4], 'tot', ARGV[5])
        redis.call('PEXPIRE', KEYS[1], ARGV[6])
        return {1, tonumber(ARGV[5]), tonumber(ARGV[3])}
        "#,
    );
    let mut connection = state.redis.get_multiplexed_async_connection().await?;
    let (result, actual_tot, actual_priority): (i32, u32, i32) = script
        .key(key)
        .arg(&owner)
        .arg(&token)
        .arg(priority)
        .arg(request.sender_demux)
        .arg(granted_tot_ms)
        .arg(granted_tot_ms)
        .invoke_async(&mut connection)
        .await?;
    Ok(Json(FloorResponse {
        granted: result != 0,
        request_token: token,
        granted_tot_ms: actual_tot,
        priority: actual_priority,
        reason: (result == 0).then_some("FLOOR_BUSY"),
    }))
}

async fn release_floor(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<FloorReleaseBody>,
) -> Result<Json<AcceptedResponse>, ApiError> {
    let authenticated = require_device(&state.pool, &headers).await?;
    let token = decode_sized(&request.request_token, 16, 16, "INVALID_REQUEST_TOKEN")?;
    let token = URL_SAFE_NO_PAD.encode(token);
    let owner = format!("{}:{}", authenticated.aci, authenticated.device_id);
    let key = format!("ptt:v1:floor:{}", request.channel_id);
    let script = redis::Script::new(
        r#"
        if redis.call('HGET', KEYS[1], 'owner') == ARGV[1] and redis.call('HGET', KEYS[1], 'token') == ARGV[2] then
          redis.call('DEL', KEYS[1])
          return 1
        end
        return 0
        "#,
    );
    let mut connection = state.redis.get_multiplexed_async_connection().await?;
    let released: i32 = script
        .key(key)
        .arg(owner)
        .arg(token)
        .invoke_async(&mut connection)
        .await?;
    if released != 1 {
        return Err(ApiError::conflict("FLOOR_NOT_HELD"));
    }
    Ok(Json(AcceptedResponse { accepted: true }))
}

async fn enforce_rate_limit(
    redis: &redis::Client,
    scope: &'static str,
    discriminator: &str,
    maximum: i64,
    window_seconds: i64,
) -> Result<(), ApiError> {
    let digest = hex::encode(hash_secret(&discriminator.to_ascii_lowercase()));
    let key = format!("ptt:v1:rate:{scope}:{}", &digest[..24]);
    let script = redis::Script::new(
        r#"
        local count = redis.call('INCR', KEYS[1])
        if count == 1 then redis.call('EXPIRE', KEYS[1], ARGV[1]) end
        return count
        "#,
    );
    let mut connection = redis.get_multiplexed_async_connection().await?;
    let count: i64 = script
        .key(key)
        .arg(window_seconds)
        .invoke_async(&mut connection)
        .await?;
    if count > maximum {
        return Err(ApiError::too_many_requests());
    }
    Ok(())
}

fn decode_sized(
    encoded: &str,
    minimum: usize,
    maximum: usize,
    error_code: &'static str,
) -> Result<Vec<u8>, ApiError> {
    let decoded = URL_SAFE_NO_PAD
        .decode(encoded.as_bytes())
        .map_err(|_| ApiError::bad_request(error_code))?;
    if !(minimum..=maximum).contains(&decoded.len()) {
        return Err(ApiError::bad_request(error_code));
    }
    Ok(decoded)
}

async fn health() -> Json<HealthResponse> {
    Json(HealthResponse {
        status: "ok",
        protocol_major: ptt_server_core::PROTOCOL_MAJOR,
        protocol_minor: ptt_server_core::PROTOCOL_MINOR,
        minimum_client_major: ptt_server_core::MINIMUM_CLIENT_MAJOR,
        minimum_client_minor: ptt_server_core::MINIMUM_CLIENT_MINOR,
        capabilities: ptt_server_core::PROTOCOL_CAPABILITIES,
    })
}

async fn ready(State(state): State<AppState>) -> impl IntoResponse {
    let database_ready = matches!(
        sqlx::query_scalar::<_, i32>("SELECT 1")
            .fetch_one(&state.pool)
            .await,
        Ok(1)
    );
    let redis_ready = match state.redis.get_multiplexed_async_connection().await {
        Ok(mut connection) => redis::cmd("PING")
            .query_async::<String>(&mut connection)
            .await
            .is_ok(),
        Err(_) => false,
    };
    let object_store_ready = match state.object_store.ready().await {
        Ok(()) => true,
        Err(error) => {
            warn!(kind = ?error, "object store readiness failed");
            false
        }
    };
    match database_ready && redis_ready && object_store_ready {
        true => (StatusCode::OK, Json(serde_json::json!({"status": "ready"}))).into_response(),
        _ => (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(serde_json::json!({"status": "not_ready"})),
        )
            .into_response(),
    }
}

async fn bootstrap(
    State(state): State<AppState>,
    Json(request): Json<BootstrapRequest>,
) -> Result<Json<BootstrapResponse>, ApiError> {
    validate_email(&request.email)?;
    if !secret_matches(&state.bootstrap_token_sha256, &request.bootstrap_token) {
        return Err(ApiError::forbidden());
    }

    let mut tx = state.pool.begin().await?;
    sqlx::query("SELECT pg_advisory_xact_lock(1347703809)")
        .execute(&mut *tx)
        .await?;
    let existing: i64 = sqlx::query_scalar(
        "SELECT (SELECT count(*) FROM accounts WHERE is_admin) + (SELECT count(*) FROM invitations WHERE grants_admin AND consumed_at IS NULL AND expires_at > now())",
    )
        .fetch_one(&mut *tx)
        .await?;
    if existing > 0 {
        return Err(ApiError::conflict("INSTANCE_ALREADY_BOOTSTRAPPED"));
    }

    let secret = IssuedSecret::issue();
    let expires_at = Utc::now() + Duration::hours(24);
    let invitation_id = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO invitations (id, email, token_sha256, grants_admin, expires_at) VALUES ($1, lower($2), $3, true, $4)",
    )
    .bind(invitation_id)
    .bind(request.email.trim())
    .bind(secret.sha256.as_slice())
    .bind(expires_at)
    .execute(&mut *tx)
    .await?;
    issue_magic_link(&mut tx, &state, invitation_id, request.email.trim(), true).await?;
    tx.commit().await?;

    Ok(Json(BootstrapResponse {
        invitation_code: secret.plaintext,
        expires_at,
    }))
}

async fn request_magic_link(
    State(state): State<AppState>,
    Json(request): Json<MagicLinkRequest>,
) -> Result<Json<AcceptedResponse>, ApiError> {
    validate_email(&request.email)?;
    enforce_rate_limit(&state.redis, "magic-link", request.email.trim(), 5, 3_600).await?;
    let invite_hash = hash_secret(&request.invitation_code);
    let mut tx = state.pool.begin().await?;
    let invite = sqlx::query_as::<_, (Uuid, String, bool)>(
        "SELECT id, email, grants_admin FROM invitations WHERE token_sha256 = $1 AND consumed_at IS NULL AND expires_at > now() FOR UPDATE",
    )
    .bind(invite_hash.as_slice())
    .fetch_optional(&mut *tx)
    .await?;

    // The response does not disclose whether an address or invite exists.
    if let Some((invite_id, invited_email, grants_admin)) = invite {
        if invited_email.eq_ignore_ascii_case(request.email.trim()) {
            issue_magic_link(&mut tx, &state, invite_id, &invited_email, grants_admin).await?;
        } else {
            warn!("invitation email mismatch");
        }
    }
    tx.commit().await?;
    Ok(Json(AcceptedResponse { accepted: true }))
}

async fn request_recovery(
    State(state): State<AppState>,
    Json(request): Json<RecoveryRequest>,
) -> Result<Json<AcceptedResponse>, ApiError> {
    validate_email(&request.email)?;
    enforce_rate_limit(&state.redis, "recovery", request.email.trim(), 5, 3_600).await?;
    let email = request.email.trim();
    let mut tx = state.pool.begin().await?;
    let account: Option<(Uuid, String)> = sqlx::query_as(
        "SELECT aci,email FROM accounts WHERE email=lower($1) AND disabled_at IS NULL FOR UPDATE",
    )
    .bind(email)
    .fetch_optional(&mut *tx)
    .await?;
    // Always return accepted so this endpoint cannot enumerate accounts.
    if let Some((aci, canonical_email)) = account {
        sqlx::query(
            "UPDATE magic_links SET consumed_at=now() WHERE email=$1 AND purpose='recover' AND consumed_at IS NULL",
        )
        .bind(&canonical_email)
        .execute(&mut *tx)
        .await?;
        let secret = IssuedSecret::issue();
        let link_id = Uuid::new_v4();
        let expires_at = Utc::now() + Duration::minutes(MAGIC_LINK_TTL_MINUTES);
        sqlx::query(
            "INSERT INTO magic_links(id,email,token_sha256,purpose,expires_at) VALUES($1,$2,$3,'recover',$4)",
        )
        .bind(link_id)
        .bind(&canonical_email)
        .bind(secret.sha256.as_slice())
        .bind(expires_at)
        .execute(&mut *tx)
        .await?;
        let url = format!(
            "{}/recover#token={}",
            state.public_base_url, secret.plaintext
        );
        sqlx::query(
            "INSERT INTO email_outbox(id,recipient,template,payload) VALUES($1,$2,'recovery_link',jsonb_build_object('url',$3,'expiresMinutes',$4))",
        )
        .bind(Uuid::new_v4())
        .bind(&canonical_email)
        .bind(url)
        .bind(MAGIC_LINK_TTL_MINUTES)
        .execute(&mut *tx)
        .await?;
        sqlx::query(
            "INSERT INTO audit_events(action,subject_hash,detail) VALUES('account.recovery_requested',$1,jsonb_build_object('aciHash',$2))",
        )
        .bind(hash_secret(&canonical_email).as_slice())
        .bind(hex::encode(hash_secret(&aci.to_string())))
        .execute(&mut *tx)
        .await?;
    }
    tx.commit().await?;
    Ok(Json(AcceptedResponse { accepted: true }))
}

async fn consume_recovery(
    State(state): State<AppState>,
    Json(request): Json<ConsumeRecoveryRequest>,
) -> Result<Json<RecoveryClaimResponse>, ApiError> {
    let device_name = request.device_name.trim();
    if device_name.is_empty() || device_name.len() > 80 {
        return Err(ApiError::bad_request("INVALID_DEVICE_NAME"));
    }
    let identity_key = decode_sized(&request.identity_key, 32, 4096, "INVALID_IDENTITY_KEY")?;
    let token_hash = hash_secret(&request.token);
    let mut tx = state.pool.begin().await?;
    let link: Option<(Uuid, Uuid)> = sqlx::query_as(
        "SELECT l.id,a.aci FROM magic_links l JOIN accounts a ON a.email=l.email WHERE l.token_sha256=$1 AND l.purpose='recover' AND l.consumed_at IS NULL AND l.expires_at > now() AND a.disabled_at IS NULL FOR UPDATE OF l,a",
    )
    .bind(token_hash.as_slice())
    .fetch_optional(&mut *tx)
    .await?;
    let (link_id, aci) = link.ok_or_else(ApiError::invalid_or_expired_link)?;
    sqlx::query(
        "UPDATE recovery_requests SET status='expired' WHERE aci=$1 AND status='pending_admin'",
    )
    .bind(aci)
    .execute(&mut *tx)
    .await?;
    let claim = IssuedSecret::issue();
    let request_id = Uuid::new_v4();
    let mailbox_id = Uuid::new_v4();
    let expires_at = Utc::now() + Duration::hours(24);
    sqlx::query(
        "INSERT INTO recovery_requests(request_id,link_id,aci,mailbox_id,device_name,identity_key,access_token_sha256,expires_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8)",
    )
    .bind(request_id)
    .bind(link_id)
    .bind(aci)
    .bind(mailbox_id)
    .bind(device_name)
    .bind(identity_key)
    .bind(claim.sha256.as_slice())
    .bind(expires_at)
    .execute(&mut *tx)
    .await?;
    sqlx::query("UPDATE magic_links SET consumed_at=now() WHERE id=$1")
        .bind(link_id)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    Ok(Json(RecoveryClaimResponse {
        request_id,
        claim_token: claim.plaintext,
        status: "pending_admin",
        expires_at,
    }))
}

async fn recovery_status(
    State(state): State<AppState>,
    Json(request): Json<RecoveryStatusRequest>,
) -> Result<Json<RecoveryStatusResponse>, ApiError> {
    let claim_hash = hash_secret(&request.claim_token);
    let mut tx = state.pool.begin().await?;
    sqlx::query(
        "UPDATE recovery_requests SET status='expired' WHERE request_id=$1 AND access_token_sha256=$2 AND status='pending_admin' AND expires_at <= now()",
    )
    .bind(request.request_id)
    .bind(claim_hash.as_slice())
    .execute(&mut *tx)
    .await?;
    let result: Option<(Uuid, Uuid, String)> = sqlx::query_as(
        "SELECT aci,mailbox_id,status::text FROM recovery_requests WHERE request_id=$1 AND access_token_sha256=$2",
    )
    .bind(request.request_id)
    .bind(claim_hash.as_slice())
    .fetch_optional(&mut *tx)
    .await?;
    tx.commit().await?;
    let (aci, mailbox_id, status) = result.ok_or_else(ApiError::invalid_or_expired_link)?;
    let approved = status == "approved";
    Ok(Json(RecoveryStatusResponse {
        status,
        aci: approved.then_some(aci),
        device_id: approved.then_some(1),
        mailbox_id: approved.then_some(mailbox_id),
    }))
}

async fn issue_magic_link(
    tx: &mut Transaction<'_, Postgres>,
    state: &AppState,
    invite_id: Uuid,
    email: &str,
    grants_admin: bool,
) -> Result<(), ApiError> {
    let secret = IssuedSecret::issue();
    let link_id = Uuid::new_v4();
    let expires_at = Utc::now() + Duration::minutes(MAGIC_LINK_TTL_MINUTES);
    sqlx::query(
        "INSERT INTO magic_links (id, invitation_id, email, token_sha256, purpose, grants_admin, expires_at) VALUES ($1, $2, lower($3), $4, $5, $6, $7)",
    )
    .bind(link_id)
    .bind(invite_id)
    .bind(email)
    .bind(secret.sha256.as_slice())
    .bind(MagicLinkPurpose::Enroll.as_str())
    .bind(grants_admin)
    .bind(expires_at)
    .execute(&mut **tx)
    .await?;

    let url = format!(
        "{}/enroll#token={}",
        state.public_base_url, secret.plaintext
    );
    sqlx::query(
        "INSERT INTO email_outbox (id, recipient, template, payload) VALUES ($1, lower($2), 'magic_link', jsonb_build_object('url', $3, 'expiresMinutes', $4))",
    )
    .bind(Uuid::new_v4())
    .bind(email)
    .bind(url)
    .bind(MAGIC_LINK_TTL_MINUTES)
    .execute(&mut **tx)
    .await?;
    Ok(())
}

async fn consume_magic_link(
    State(state): State<AppState>,
    Json(request): Json<ConsumeMagicLinkRequest>,
) -> Result<Json<EnrolledDeviceResponse>, ApiError> {
    if request.device_name.trim().is_empty() || request.device_name.len() > 80 {
        return Err(ApiError::bad_request("INVALID_DEVICE_NAME"));
    }
    let identity_key = URL_SAFE_NO_PAD
        .decode(request.identity_key.as_bytes())
        .map_err(|_| ApiError::bad_request("INVALID_IDENTITY_KEY"))?;
    if !(32..=4096).contains(&identity_key.len()) {
        return Err(ApiError::bad_request("INVALID_IDENTITY_KEY"));
    }
    decode_sized(&request.resume_secret, 32, 32, "INVALID_RESUME_SECRET")?;

    let token_hash = hash_secret(&request.token);
    let resume_hash = hash_secret(&request.resume_secret);
    let mut tx = state.pool.begin().await?;
    let link = sqlx::query_as::<_, (Uuid, Uuid, String, bool)>(
        "SELECT id, invitation_id, email, grants_admin FROM magic_links WHERE token_sha256 = $1 AND purpose='enroll' AND invitation_id IS NOT NULL AND consumed_at IS NULL AND expires_at > now() FOR UPDATE",
    )
    .bind(token_hash.as_slice())
    .fetch_optional(&mut *tx)
    .await?;

    if link.is_none() {
        let enrolled = sqlx::query_as::<_, (Uuid, Uuid, Vec<u8>, String)>(
            "SELECT a.aci,d.mailbox_id,d.identity_key,l.email FROM magic_links l JOIN accounts a ON a.email=l.email JOIN devices d ON d.aci=a.aci AND d.device_id=1 WHERE l.token_sha256=$1 AND l.purpose='enroll' AND l.consumed_at IS NOT NULL AND l.expires_at>now() AND l.resume_secret_sha256=$2 AND d.identity_key=$3 AND d.status='active' FOR UPDATE OF l,d",
        )
        .bind(token_hash.as_slice())
        .bind(resume_hash.as_slice())
        .bind(&identity_key)
        .fetch_optional(&mut *tx)
        .await?;
        let Some((aci, mailbox_id, _, email)) = enrolled else {
            return Err(ApiError::invalid_or_expired_link());
        };
        let access = IssuedSecret::issue();
        let updated = sqlx::query(
            "UPDATE devices SET access_token_sha256=$1 WHERE aci=$2 AND device_id=1 AND identity_key=$3 AND status='active'",
        )
        .bind(access.sha256.as_slice())
        .bind(aci)
        .bind(&identity_key)
        .execute(&mut *tx)
        .await?;
        if updated.rows_affected() != 1 {
            return Err(ApiError::conflict("ENROLLMENT_CONFLICT"));
        }
        sqlx::query(
            "INSERT INTO audit_events(actor_aci,action,subject_hash,detail) VALUES($1,'account.enrollment_resumed',$2,jsonb_build_object('deviceId',1))",
        )
        .bind(aci)
        .bind(hash_secret(&email).as_slice())
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        return Ok(Json(EnrolledDeviceResponse {
            aci,
            device_id: 1,
            mailbox_id,
            access_token: access.plaintext,
        }));
    }

    let (link_id, invitation_id, email, grants_admin) = link.expect("checked above");
    let existing = sqlx::query_as::<_, (Uuid, bool)>(
        "SELECT aci, is_admin FROM accounts WHERE email = lower($1) FOR UPDATE",
    )
    .bind(&email)
    .fetch_optional(&mut *tx)
    .await?;
    if existing.is_some() {
        return Err(ApiError::conflict("DEVICE_LINK_APPROVAL_REQUIRED"));
    }
    let aci = {
        let aci = Uuid::new_v4();
        sqlx::query("INSERT INTO accounts (aci, email, is_admin) VALUES ($1, lower($2), $3)")
            .bind(aci)
            .bind(&email)
            .bind(grants_admin)
            .execute(&mut *tx)
            .await?;
        aci
    };

    let active_ids: Vec<i32> = sqlx::query_scalar(
        "SELECT device_id FROM devices WHERE aci = $1 AND status = 'active' ORDER BY device_id FOR UPDATE",
    )
    .bind(aci)
    .fetch_all(&mut *tx)
    .await?;
    let device_id = (1..=2)
        .find(|candidate| !active_ids.contains(candidate))
        .ok_or_else(ApiError::device_limit)?;
    let mailbox_id = Uuid::new_v4();
    let access = IssuedSecret::issue();
    sqlx::query(
        "INSERT INTO devices (aci, device_id, mailbox_id, display_name, identity_key, access_token_sha256, status) VALUES ($1, $2, $3, $4, $5, $6, 'active')",
    )
    .bind(aci)
    .bind(device_id)
    .bind(mailbox_id)
    .bind(request.device_name.trim())
    .bind(identity_key)
    .bind(access.sha256.as_slice())
    .execute(&mut *tx)
    .await?;
    sqlx::query("UPDATE magic_links SET consumed_at = now(),resume_secret_sha256=$2 WHERE id = $1")
        .bind(link_id)
        .bind(resume_hash.as_slice())
        .execute(&mut *tx)
        .await?;
    sqlx::query("UPDATE invitations SET consumed_at = now() WHERE id = $1")
        .bind(invitation_id)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;

    Ok(Json(EnrolledDeviceResponse {
        aci,
        device_id,
        mailbox_id,
        access_token: access.plaintext,
    }))
}

fn validate_email(email: &str) -> Result<(), ApiError> {
    let email = email.trim();
    if email.len() > 254 || !email.contains('@') || email.starts_with('@') || email.ends_with('@') {
        Err(ApiError::bad_request("INVALID_EMAIL"))
    } else {
        Ok(())
    }
}

async fn enrollment_landing() -> impl IntoResponse {
    secure_app_landing(
        "enroll",
        "Continue enrollment",
        "Open PTT Talk to finish enrollment.",
    )
}

async fn recovery_landing() -> impl IntoResponse {
    secure_app_landing(
        "recover",
        "Continue recovery",
        "Open PTT Talk to request administrator approval.",
    )
}

fn secure_app_landing(
    _action: &'static str,
    title: &'static str,
    description: &'static str,
) -> impl IntoResponse {
    let nonce = Uuid::new_v4().simple().to_string();
    let page = format!(
        r#"<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="referrer" content="no-referrer"><title>{title}</title><style nonce="{nonce}">body{{font:16px system-ui;margin:0;background:#eef3f0;color:#13201c}}main{{max-width:32rem;margin:12vh auto;padding:2rem;background:white;border-radius:1rem}}button{{display:block;width:100%;border:0;margin-top:1.5rem;padding:1rem;text-align:center;border-radius:.75rem;background:#08755c;color:white;font:inherit;font-weight:700}}p{{line-height:1.5;color:#345249}}</style></head><body><main><h1>{title}</h1><p>{description}</p><button id="continue" type="button">Copy one-time code</button><p id="copied" hidden>Code copied. Open PTT Talk and choose manual setup.</p><p id="error" hidden>This link is incomplete. Request a new email from PTT Talk.</p></main><script nonce="{nonce}">const p=new URLSearchParams(location.hash.slice(1));const t=p.get('token');history.replaceState(null,'',location.pathname);const a=document.getElementById('continue');if(t){{a.onclick=async()=>{{await navigator.clipboard.writeText(t);document.getElementById('copied').hidden=false}}}}else{{a.hidden=true;document.getElementById('error').hidden=false}}</script></body></html>"#,
    );
    let mut headers = HeaderMap::new();
    headers.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    headers.insert(
        header::REFERRER_POLICY,
        HeaderValue::from_static("no-referrer"),
    );
    headers.insert(
        HeaderName::from_static("content-security-policy"),
        HeaderValue::from_str(&format!(
            "default-src 'none'; script-src 'nonce-{nonce}'; style-src 'nonce-{nonce}'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
        ))
        .expect("generated CSP is a valid header"),
    );
    (headers, Html(page))
}

async fn shutdown() {
    let ctrl_c = async {
        tokio::signal::ctrl_c()
            .await
            .expect("install ctrl-c handler")
    };
    #[cfg(unix)]
    let terminate = async {
        tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
            .expect("install terminate handler")
            .recv()
            .await;
    };
    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();
    tokio::select! { _ = ctrl_c => {}, _ = terminate => {} }
}

#[derive(Debug)]
struct ApiError {
    status: StatusCode,
    code: &'static str,
    message: &'static str,
}

impl ApiError {
    fn bad_request(code: &'static str) -> Self {
        Self {
            status: StatusCode::BAD_REQUEST,
            code,
            message: "The request is invalid.",
        }
    }
    fn too_many_requests() -> Self {
        Self {
            status: StatusCode::TOO_MANY_REQUESTS,
            code: "RATE_LIMITED",
            message: "Too many requests. Try again later.",
        }
    }
    fn forbidden() -> Self {
        Self {
            status: StatusCode::FORBIDDEN,
            code: "FORBIDDEN",
            message: "Permission denied.",
        }
    }
    fn forbidden_code(code: &'static str) -> Self {
        Self {
            status: StatusCode::FORBIDDEN,
            code,
            message: "Permission denied.",
        }
    }
    fn unauthenticated() -> Self {
        Self {
            status: StatusCode::UNAUTHORIZED,
            code: "UNAUTHENTICATED",
            message: "Authentication is required.",
        }
    }
    fn conflict(code: &'static str) -> Self {
        Self {
            status: StatusCode::CONFLICT,
            code,
            message: "The request conflicts with current state.",
        }
    }
    fn not_found(code: &'static str) -> Self {
        Self {
            status: StatusCode::NOT_FOUND,
            code,
            message: "The requested item was not found.",
        }
    }
    fn gone(code: &'static str) -> Self {
        Self {
            status: StatusCode::GONE,
            code,
            message: "The requested item has expired.",
        }
    }
    fn invalid_range() -> Self {
        Self {
            status: StatusCode::RANGE_NOT_SATISFIABLE,
            code: "INVALID_RANGE",
            message: "The requested byte range is invalid.",
        }
    }
    fn unavailable(code: &'static str) -> Self {
        Self {
            status: StatusCode::SERVICE_UNAVAILABLE,
            code,
            message: "The requested item is temporarily unavailable.",
        }
    }
    fn invalid_or_expired_link() -> Self {
        Self {
            status: StatusCode::UNAUTHORIZED,
            code: "INVALID_OR_EXPIRED_LINK",
            message: "The sign-in link is invalid or expired.",
        }
    }
    fn device_limit() -> Self {
        Self {
            status: StatusCode::CONFLICT,
            code: "DEVICE_LIMIT",
            message: "This account already has two active devices.",
        }
    }
    fn internal() -> Self {
        Self {
            status: StatusCode::INTERNAL_SERVER_ERROR,
            code: "INTERNAL",
            message: "The request could not be completed.",
        }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> axum::response::Response {
        (
            self.status,
            Json(ErrorBody {
                code: self.code,
                message: self.message,
            }),
        )
            .into_response()
    }
}

impl From<sqlx::Error> for ApiError {
    fn from(error: sqlx::Error) -> Self {
        tracing::error!(error = %error, "database operation failed");
        Self {
            status: StatusCode::INTERNAL_SERVER_ERROR,
            code: "INTERNAL",
            message: "The request could not be completed.",
        }
    }
}

impl From<redis::RedisError> for ApiError {
    fn from(error: redis::RedisError) -> Self {
        tracing::error!(kind = ?error.kind(), "Redis operation failed");
        ApiError::internal()
    }
}

impl From<ObjectStoreError> for ApiError {
    fn from(error: ObjectStoreError) -> Self {
        tracing::error!(kind = ?error, "object-store operation failed");
        ApiError::internal()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_email_shape_without_normalizing_secrets() {
        assert!(validate_email("person@example.com").is_ok());
        assert!(validate_email("missing-at.example.com").is_err());
        assert!(validate_email("@example.com").is_err());
    }

    fn mailbox_batch(now: DateTime<Utc>) -> MailboxEnvelopeBatchRequest {
        MailboxEnvelopeBatchRequest {
            message_id: Uuid::new_v4(),
            recipients: vec![MailboxRecipientInput {
                aci: Uuid::new_v4(),
                device_id: 1,
                envelope: URL_SAFE_NO_PAD.encode([1_u8, 2, 3]),
            }],
            expires_at: now + Duration::minutes(5),
        }
    }

    #[test]
    fn validates_and_decodes_mailbox_envelopes() {
        let now = Utc::now();
        let decoded = validate_mailbox_batch(&mailbox_batch(now), now).expect("valid batch");
        assert_eq!(decoded.len(), 1);
        assert_eq!(decoded[0].device_id, 1);
        assert_eq!(decoded[0].envelope, [1_u8, 2, 3]);
    }

    #[test]
    fn rejects_duplicate_mailbox_recipients() {
        let now = Utc::now();
        let mut request = mailbox_batch(now);
        request.recipients.push(MailboxRecipientInput {
            aci: request.recipients[0].aci,
            device_id: request.recipients[0].device_id,
            envelope: URL_SAFE_NO_PAD.encode([4_u8]),
        });
        let error = validate_mailbox_batch(&request, now).expect_err("duplicate recipient");
        assert_eq!(error.code, "INVALID_RECIPIENTS");
    }

    #[test]
    fn rejects_expired_or_excessive_mailbox_ttl() {
        let now = Utc::now();
        let mut request = mailbox_batch(now);
        request.expires_at = now;
        assert_eq!(
            validate_mailbox_batch(&request, now)
                .expect_err("expired batch")
                .code,
            "INVALID_ENVELOPE_BATCH"
        );
        request.expires_at = now + Duration::days(MAX_MAILBOX_TTL_DAYS + 1);
        assert_eq!(
            validate_mailbox_batch(&request, now)
                .expect_err("excessive ttl")
                .code,
            "INVALID_ENVELOPE_BATCH"
        );
    }

    #[test]
    fn rejects_invalid_mailbox_envelopes_and_device_ids() {
        let now = Utc::now();
        let mut request = mailbox_batch(now);
        request.recipients[0].envelope = "not-base64!".to_owned();
        assert_eq!(
            validate_mailbox_batch(&request, now)
                .expect_err("invalid envelope")
                .code,
            "INVALID_ENVELOPE"
        );
        request.recipients[0].envelope = URL_SAFE_NO_PAD.encode([1_u8]);
        request.recipients[0].device_id = 3;
        assert_eq!(
            validate_mailbox_batch(&request, now)
                .expect_err("invalid device")
                .code,
            "INVALID_RECIPIENTS"
        );
    }

    fn history_upload(now: DateTime<Utc>) -> HistoryUploadRequest {
        HistoryUploadRequest {
            talk_id: Uuid::new_v4(),
            channel_id: Uuid::new_v4(),
            membership_epoch: 1,
            media_kid: u64::MAX.to_string(),
            started_at: now - Duration::seconds(1),
            duration_ms: 1_000,
            ciphertext: URL_SAFE_NO_PAD.encode([7_u8; 128]),
        }
    }

    #[test]
    fn validates_history_without_losing_uint64_media_kid() {
        let now = Utc::now();
        let (media_kid, ciphertext, digest) =
            validate_history_upload(&history_upload(now), now).expect("valid history");
        assert_eq!(media_kid, u64::MAX);
        assert_eq!(ciphertext, [7_u8; 128]);
        assert_eq!(digest.as_slice(), Sha256::digest(&ciphertext).as_slice());
    }

    #[test]
    fn rejects_invalid_history_metadata_and_ciphertext() {
        let now = Utc::now();
        let mut request = history_upload(now);
        request.duration_ms = MAX_HISTORY_DURATION_MS + 1;
        assert_eq!(
            validate_history_upload(&request, now)
                .expect_err("duration")
                .code,
            "INVALID_HISTORY_OBJECT"
        );
        request.duration_ms = 1;
        request.media_kid = "18446744073709551616".to_owned();
        assert_eq!(
            validate_history_upload(&request, now)
                .expect_err("media kid overflow")
                .code,
            "INVALID_MEDIA_KID"
        );
        request.media_kid = "1".to_owned();
        request.ciphertext = String::new();
        assert_eq!(
            validate_history_upload(&request, now)
                .expect_err("empty ciphertext")
                .code,
            "INVALID_HISTORY_CIPHERTEXT"
        );
    }

    #[test]
    fn accepts_only_supported_push_providers() {
        for provider in [
            "fcm",
            "apns",
            "apns-ptt",
            "apns-sandbox",
            "apns-ptt-sandbox",
        ] {
            assert!(validate_push_provider(provider).is_ok());
        }
        assert_eq!(
            validate_push_provider("web-push")
                .expect_err("unsupported provider")
                .code,
            "INVALID_PUSH_PROVIDER"
        );
    }

    #[test]
    fn prometheus_metrics_are_aggregate_and_unlabelled() {
        let output = format_metrics(&MetricsSnapshot {
            accounts: 2,
            active_devices: 3,
            channels: 1,
            active_relay_leases: 1,
            pending_email: 0,
            pending_recoveries: 0,
            pending_push: 4,
            failed_push: 1,
            history_objects: 5,
            history_ciphertext_bytes: 1024,
            database_connections: 2,
            database_idle_connections: 1,
        });
        assert!(output.contains("ptt_active_devices 3\n"));
        assert!(output.contains("ptt_history_ciphertext_bytes 1024\n"));
        assert!(!output.contains('{'));
        assert!(!output.contains("aci"));
        assert!(!output.contains("email="));
        assert!(!output.contains("channel_id"));
    }
}
