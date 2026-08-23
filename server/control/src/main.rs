use anyhow::{Context, Result};
use axum::{
    extract::State,
    http::{HeaderMap, HeaderName, StatusCode},
    response::IntoResponse,
    routing::{get, post},
    Json, Router,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use chrono::{Duration, Utc};
use lettre::{
    message::Mailbox,
    transport::smtp::{
        authentication::Credentials,
        client::{Tls, TlsParameters},
    },
    AsyncSmtpTransport, AsyncTransport, Message, Tokio1Executor,
};
use ptt_server_core::{
    hash_secret, issue_relay_ticket, secret_matches, IssuedSecret, MagicLinkPurpose,
    MAGIC_LINK_TTL_MINUTES, MAX_PREKEY_BATCH_DEVICES,
};
use rand::Rng;
use serde::{Deserialize, Serialize};
use sqlx::{postgres::PgPoolOptions, PgPool, Postgres, Transaction};
use std::{env, net::SocketAddr, sync::Arc};
use tower_http::{
    catch_panic::CatchPanicLayer,
    request_id::{MakeRequestUuid, PropagateRequestIdLayer, SetRequestIdLayer},
    trace::TraceLayer,
};
use tracing::{info, warn};
use uuid::Uuid;

#[derive(Clone)]
struct AppState {
    pool: PgPool,
    public_base_url: Arc<str>,
    bootstrap_token_sha256: [u8; 32],
    relay_signing_key: Arc<[u8]>,
    relay_public_address: Arc<str>,
    redis: redis::Client,
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
struct HealthResponse {
    status: &'static str,
    protocol_major: u32,
    protocol_minor: u32,
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
}

#[derive(Debug, Clone, Copy)]
struct AuthenticatedDevice {
    aci: Uuid,
    device_id: i32,
    is_admin: bool,
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
#[serde(rename_all = "camelCase")]
struct UploadPreKeysRequest {
    opaque_bundle: String,
    one_time_prekeys: Vec<OneTimePreKeyInput>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct OneTimePreKeyInput {
    kind: String,
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
    };
    if let Some(smtp) = smtp_settings()? {
        tokio::spawn(email_worker(state.pool.clone(), smtp));
    } else {
        warn!("SMTP is not configured; enrollment email remains queued");
    }
    let app = app(state);
    let bind: SocketAddr = env::var("PTT_CONTROL_BIND")
        .unwrap_or_else(|_| "0.0.0.0:8080".to_owned())
        .parse()
        .context("parse PTT_CONTROL_BIND")?;
    let listener = tokio::net::TcpListener::bind(bind).await?;
    info!(%bind, "control service ready");
    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown())
        .await?;
    Ok(())
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
        .route("/v1/bootstrap", post(bootstrap))
        .route("/v1/auth/magic-link/request", post(request_magic_link))
        .route("/v1/auth/magic-link/consume", post(consume_magic_link))
        .route("/v1/devices", get(list_devices))
        .route("/v1/devices/revoke", post(revoke_device))
        .route("/v1/devices/link/start", post(start_device_link))
        .route("/v1/devices/link/claim", post(claim_device_link))
        .route("/v1/devices/link/approve", post(approve_device_link))
        .route("/v1/devices/link/status", post(device_link_status))
        .route("/v1/prekeys/upload", post(upload_prekeys))
        .route("/v1/prekeys/fetch", post(fetch_prekeys))
        .route("/v1/relay/credentials", post(relay_credentials))
        .route("/v1/floor/request", post(request_floor))
        .route("/v1/floor/release", post(release_floor))
        .route("/v1/admin/summary", get(admin_summary))
        .route("/v1/admin/members", get(admin_members))
        .route("/v1/admin/invitations", post(create_invitation))
        .route(
            "/v1/admin/channels",
            get(admin_channels).post(create_channel),
        )
        .route(
            "/v1/admin/channels/membership",
            post(update_channel_membership),
        )
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
    Ok(Json(AdminSummary {
        accounts,
        active_devices,
        channels,
        pending_email,
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
    if !matches!(request.kind.as_str(), "team" | "duty" | "adhoc") {
        return Err(ApiError::bad_request("INVALID_CHANNEL_KIND"));
    }
    if !(1..=365).contains(&request.retention_days) {
        return Err(ApiError::bad_request("INVALID_RETENTION"));
    }
    if request.members.is_empty() || request.members.len() > 64 {
        return Err(ApiError::bad_request("INVALID_MEMBERS"));
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
    let epoch: Option<i32> = sqlx::query_scalar(
        "UPDATE channels SET membership_epoch = membership_epoch + 1, distribution_id = gen_random_uuid() WHERE channel_id = $1 RETURNING membership_epoch",
    )
    .bind(request.channel_id)
    .fetch_optional(&mut *tx)
    .await?;
    let epoch = epoch.ok_or_else(|| ApiError::bad_request("UNKNOWN_CHANNEL"))?;
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
        let member_count: i64 = sqlx::query_scalar(
            "SELECT count(*) FROM memberships WHERE channel_id = $1 AND left_epoch IS NULL",
        )
        .bind(request.channel_id)
        .fetch_one(&mut *tx)
        .await?;
        if member_count >= 64 {
            return Err(ApiError::conflict("CHANNEL_MEMBER_LIMIT"));
        }
        sqlx::query(
            "INSERT INTO memberships(channel_id, aci, role, joined_epoch, left_epoch) VALUES ($1, $2, $3, $4, NULL) ON CONFLICT(channel_id, aci) DO UPDATE SET role = excluded.role, joined_epoch = excluded.joined_epoch, left_epoch = NULL",
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
    let mut tx = state.pool.begin().await?;
    sqlx::query(
        "INSERT INTO invitations (id, email, token_sha256, grants_admin, expires_at) VALUES ($1, lower($2), $3, false, $4)",
    )
    .bind(Uuid::new_v4())
    .bind(request.email.trim())
    .bind(secret.sha256.as_slice())
    .bind(expires_at)
    .execute(&mut *tx)
    .await?;
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
    sqlx::query(
        "UPDATE devices SET status = 'active', linked_at = now() WHERE aci = $1 AND device_id = $2 AND status = 'pending'",
    )
    .bind(authenticated.aci)
    .bind(claimed_device_id)
    .execute(&mut *tx)
    .await?;
    sqlx::query("UPDATE device_link_requests SET approved_at = now() WHERE request_id = $1")
        .bind(request.request_id)
        .execute(&mut *tx)
        .await?;
    sqlx::query(
        "INSERT INTO audit_events(actor_aci, action, subject_hash, detail) VALUES ($1, 'device.linked', $2, jsonb_build_object('deviceId', $3))",
    )
    .bind(authenticated.aci)
    .bind(hash_secret(&format!(
        "{}:{}",
        authenticated.aci, claimed_device_id
    )).as_slice())
    .bind(claimed_device_id)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
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
    if !(1..=2).contains(&request.device_id) {
        return Err(ApiError::bad_request("INVALID_DEVICE_ID"));
    }
    let mut tx = state.pool.begin().await?;
    let target_active: Option<bool> = sqlx::query_scalar(
        "SELECT true FROM devices WHERE aci = $1 AND device_id = $2 AND status = 'active' FOR UPDATE",
    )
    .bind(authenticated.aci)
    .bind(request.device_id)
    .fetch_optional(&mut *tx)
    .await?;
    if target_active.is_none() {
        return Err(ApiError::conflict("DEVICE_NOT_ACTIVE"));
    }

    if authenticated.is_admin {
        let other_admin_devices: i64 = sqlx::query_scalar(
            "SELECT count(*) FROM devices d JOIN accounts a ON a.aci = d.aci WHERE a.is_admin AND a.disabled_at IS NULL AND d.status = 'active' AND NOT (d.aci = $1 AND d.device_id = $2)",
        )
        .bind(authenticated.aci)
        .bind(request.device_id)
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
    .bind(authenticated.aci)
    .bind(request.device_id)
    .bind(invalidated_access.sha256.as_slice())
    .execute(&mut *tx)
    .await?;
    sqlx::query(
        "UPDATE channels c SET membership_epoch = membership_epoch + 1, distribution_id = gen_random_uuid() FROM memberships m WHERE m.channel_id = c.channel_id AND m.aci = $1 AND m.left_epoch IS NULL",
    )
    .bind(authenticated.aci)
    .execute(&mut *tx)
    .await?;
    sqlx::query(
        "INSERT INTO audit_events(actor_aci, action, subject_hash, detail) VALUES ($1, 'device.revoked', $3, jsonb_build_object('deviceId', $2))",
    )
    .bind(authenticated.aci)
    .bind(request.device_id)
    .bind(hash_secret(&format!("{}:{}", authenticated.aci, request.device_id)).as_slice())
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(Json(AcceptedResponse { accepted: true }))
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
        if item.kind != "x25519" && item.kind != "kyber" {
            return Err(ApiError::bad_request("INVALID_PREKEY_KIND"));
        }
        decoded.push((
            item.kind,
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
    for (kind, public_key) in decoded {
        sqlx::query(
            "INSERT INTO one_time_prekeys(aci, device_id, kind, public_key) VALUES ($1, $2, $3, $4)",
        )
        .bind(authenticated.aci)
        .bind(authenticated.device_id)
        .bind(kind)
        .bind(public_key)
        .execute(&mut *tx)
        .await?;
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
            let key: Option<Vec<u8>> = sqlx::query_scalar(
                "UPDATE one_time_prekeys SET consumed_at = now() WHERE id = (SELECT id FROM one_time_prekeys WHERE aci = $1 AND device_id = $2 AND kind = $3 AND consumed_at IS NULL ORDER BY id FOR UPDATE SKIP LOCKED LIMIT 1) RETURNING public_key",
            )
            .bind(device.aci)
            .bind(device.device_id)
            .bind(kind)
            .fetch_optional(&mut *tx)
            .await?;
            if let Some(public_key) = key {
                one_time_prekeys.push(OneTimePreKeyResponse {
                    kind: kind.to_owned(),
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
        "INSERT INTO relay_leases(channel_id, sender_demux, aci, device_id, expires_at) VALUES ($1, $2, $3, $4, $5) ON CONFLICT(channel_id, aci, device_id) DO UPDATE SET sender_demux = excluded.sender_demux, expires_at = excluded.expires_at",
    )
    .bind(request.channel_id)
    .bind(sender_demux as i64)
    .bind(authenticated.aci)
    .bind(authenticated.device_id)
    .bind(expires_at)
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
    let membership: Option<(i32, String)> = sqlx::query_as(
        "SELECT c.membership_epoch, m.role FROM channels c JOIN memberships m ON m.channel_id = c.channel_id WHERE c.channel_id = $1 AND m.aci = $2 AND m.left_epoch IS NULL",
    )
    .bind(request.channel_id)
    .bind(authenticated.aci)
    .fetch_optional(&state.pool)
    .await?;
    let (membership_epoch, role) = membership.ok_or_else(ApiError::forbidden)?;
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
    match database_ready && redis_ready {
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
    sqlx::query(
        "INSERT INTO invitations (id, email, token_sha256, grants_admin, expires_at) VALUES ($1, lower($2), $3, true, $4)",
    )
    .bind(Uuid::new_v4())
    .bind(request.email.trim())
    .bind(secret.sha256.as_slice())
    .bind(expires_at)
    .execute(&mut *tx)
    .await?;
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
        "{}/enroll?token={}",
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

    let token_hash = hash_secret(&request.token);
    let mut tx = state.pool.begin().await?;
    let link = sqlx::query_as::<_, (Uuid, Uuid, String, bool)>(
        "SELECT id, invitation_id, email, grants_admin FROM magic_links WHERE token_sha256 = $1 AND consumed_at IS NULL AND expires_at > now() FOR UPDATE",
    )
    .bind(token_hash.as_slice())
    .fetch_optional(&mut *tx)
    .await?
    .ok_or_else(ApiError::invalid_or_expired_link)?;

    let (link_id, invitation_id, email, grants_admin) = link;
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
    sqlx::query("UPDATE magic_links SET consumed_at = now() WHERE id = $1")
        .bind(link_id)
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
    fn forbidden() -> Self {
        Self {
            status: StatusCode::FORBIDDEN,
            code: "FORBIDDEN",
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_email_shape_without_normalizing_secrets() {
        assert!(validate_email("person@example.com").is_ok());
        assert!(validate_email("missing-at.example.com").is_err());
        assert!(validate_email("@example.com").is_err());
    }
}
