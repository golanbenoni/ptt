use crate::{require_device, ApiError, AppState, AuthenticatedDevice};
use axum::{
    body::Bytes,
    extract::{ws::Message, Path, State, WebSocketUpgrade},
    http::{header, HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    Json,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use chrono::{DateTime, Duration, Utc};
use futures_util::StreamExt;
use jsonwebtoken::{decode, encode, Algorithm, DecodingKey, EncodingKey, Header, Validation};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use sqlx::{PgPool, Postgres, Transaction};
use std::{
    collections::{HashMap, HashSet},
    env,
    sync::Arc,
};
use subtle::ConstantTimeEq;
use tokio::sync::{broadcast, RwLock};
use uuid::Uuid;

const CALL_RING_SECONDS: i64 = 45;
const CALL_MAX_SECONDS: i64 = 8 * 60 * 60;

#[derive(Clone)]
pub(crate) struct CallConfig {
    public_url: Arc<str>,
    api_key: Arc<str>,
    signing_key: Arc<EncodingKey>,
    verification_key: Arc<DecodingKey>,
    health_url: Arc<str>,
    health_client: reqwest::Client,
}

impl CallConfig {
    pub(crate) fn from_env() -> anyhow::Result<Option<Self>> {
        let values = (
            env::var("PTT_LIVEKIT_URL").ok(),
            env::var("PTT_LIVEKIT_API_KEY").ok(),
            env::var("PTT_LIVEKIT_API_SECRET").ok(),
        );
        let (Some(url), Some(api_key), Some(api_secret)) = values else {
            if values.0.is_some() || values.1.is_some() || values.2.is_some() {
                anyhow::bail!("PTT_LIVEKIT_URL, PTT_LIVEKIT_API_KEY, and PTT_LIVEKIT_API_SECRET must be configured together");
            }
            return Ok(None);
        };
        let parsed = reqwest::Url::parse(url.trim())?;
        let host = parsed.host_str().unwrap_or_default();
        let loopback = host.eq_ignore_ascii_case("localhost")
            || host
                .parse::<std::net::IpAddr>()
                .map(|address| address.is_loopback())
                .unwrap_or(false);
        let insecure_loopback = parsed.scheme() == "ws"
            && loopback
            && env::var("PTT_ALLOW_INSECURE_LOOPBACK").as_deref() == Ok("1");
        if (parsed.scheme() != "wss" && !insecure_loopback)
            || parsed.host_str().is_none()
            || !parsed.username().is_empty()
            || parsed.password().is_some()
            || parsed.query().is_some()
            || parsed.fragment().is_some()
        {
            anyhow::bail!("PTT_LIVEKIT_URL must be a canonical wss URL");
        }
        if api_key.trim().is_empty() || api_secret.len() < 32 {
            anyhow::bail!("LiveKit credentials are incomplete");
        }
        let mut health_url = parsed.clone();
        health_url
            .set_scheme(if insecure_loopback { "http" } else { "https" })
            .map_err(|_| anyhow::anyhow!("derive LiveKit health URL"))?;
        health_url.set_path("/");
        let health_client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(2))
            .redirect(reqwest::redirect::Policy::none())
            .build()?;
        Ok(Some(Self {
            public_url: parsed.to_string().trim_end_matches('/').to_owned().into(),
            api_key: api_key.into(),
            signing_key: Arc::new(EncodingKey::from_secret(api_secret.as_bytes())),
            verification_key: Arc::new(DecodingKey::from_secret(api_secret.as_bytes())),
            health_url: health_url.to_string().into(),
            health_client,
        }))
    }

    fn token(&self, room: &str, identity: &str) -> Result<String, ApiError> {
        let issued_at = Utc::now().timestamp();
        let claims = LiveKitClaims {
            iss: &self.api_key,
            sub: identity,
            aud: &self.public_url,
            nbf: issued_at - 5,
            exp: issued_at + 300,
            video: LiveKitVideoGrant {
                room_join: true,
                room,
                can_publish: true,
                can_subscribe: true,
                can_publish_data: false,
                room_create: false,
                room_admin: false,
                room_record: false,
            },
        };
        encode(&Header::new(Algorithm::HS256), &claims, &self.signing_key)
            .map_err(|_| ApiError::internal())
    }

    fn admin_token(&self, room: &str, action_type: &str) -> Result<String, ApiError> {
        let issued_at = Utc::now().timestamp();
        let delete_room = action_type == "delete_room";
        let remove_participant = action_type == "remove_participant";
        let claims = LiveKitClaims {
            iss: &self.api_key,
            sub: "ptt-control",
            aud: &self.public_url,
            nbf: issued_at - 5,
            exp: issued_at + 60,
            video: LiveKitVideoGrant {
                room_join: false,
                room,
                can_publish: false,
                can_subscribe: false,
                can_publish_data: false,
                room_create: delete_room,
                room_admin: remove_participant,
                room_record: false,
            },
        };
        encode(&Header::new(Algorithm::HS256), &claims, &self.signing_key)
            .map_err(|_| ApiError::internal())
    }

    async fn perform_media_action(&self, action: &MediaActionRow) -> Result<(), &'static str> {
        let method = match action.action_type.as_str() {
            "remove_participant" => "RemoveParticipant",
            "delete_room" => "DeleteRoom",
            _ => return Err("invalid_action"),
        };
        let mut endpoint =
            reqwest::Url::parse(self.health_url.as_ref()).map_err(|_| "invalid_endpoint")?;
        endpoint.set_path(&format!("/twirp/livekit.RoomService/{method}"));
        let payload = if method == "RemoveParticipant" {
            serde_json::json!({
                "room": action.livekit_room_name,
                "identity": action.livekit_identity,
            })
        } else {
            serde_json::json!({ "room": action.livekit_room_name })
        };
        let token = self
            .admin_token(&action.livekit_room_name, &action.action_type)
            .map_err(|_| "token_failed")?;
        let response = self
            .health_client
            .post(endpoint)
            .bearer_auth(token)
            .header(header::CONTENT_TYPE, "application/json")
            .json(&payload)
            .send()
            .await
            .map_err(|_| "transport_failed")?;
        if response.status().is_success() || response.status() == StatusCode::NOT_FOUND {
            Ok(())
        } else if response.status() == StatusCode::UNAUTHORIZED
            || response.status() == StatusCode::FORBIDDEN
        {
            Err("authorization_failed")
        } else {
            Err("media_api_failed")
        }
    }

    async fn media_ready(&self) -> bool {
        self.health_client
            .get(self.health_url.as_ref())
            .send()
            .await
            .map(|response| response.status().is_success())
            .unwrap_or(false)
    }

    fn verify_webhook(&self, headers: &HeaderMap, body: &[u8]) -> Result<(), ApiError> {
        if body.is_empty() || body.len() > 256 * 1024 {
            return Err(ApiError::bad_request("INVALID_WEBHOOK_BODY"));
        }
        let content_type = headers
            .get(header::CONTENT_TYPE)
            .and_then(|value| value.to_str().ok())
            .unwrap_or_default();
        if !content_type
            .to_ascii_lowercase()
            .starts_with("application/webhook+json")
        {
            return Err(ApiError::bad_request("INVALID_WEBHOOK_CONTENT_TYPE"));
        }
        let token = headers
            .get(header::AUTHORIZATION)
            .and_then(|value| value.to_str().ok())
            .ok_or_else(ApiError::unauthenticated)?;
        let token = token.strip_prefix("Bearer ").unwrap_or(token);
        let mut validation = Validation::new(Algorithm::HS256);
        validation.set_issuer(&[self.api_key.as_ref()]);
        validation.validate_nbf = true;
        validation.leeway = 10;
        let verified = decode::<LiveKitWebhookClaims>(token, &self.verification_key, &validation)
            .map_err(|_| ApiError::unauthenticated())?;
        let expected = base64::engine::general_purpose::STANDARD.encode(Sha256::digest(body));
        if !bool::from(expected.as_bytes().ct_eq(verified.claims.sha256.as_bytes())) {
            return Err(ApiError::unauthenticated());
        }
        Ok(())
    }
}

const CALL_EVENT_REDIS_CHANNEL: &str = "ptt:call-events:v1";

#[derive(Clone)]
pub(crate) struct CallEventHub {
    senders: Arc<RwLock<HashMap<Uuid, broadcast::Sender<String>>>>,
    redis: redis::Client,
    origin: Uuid,
}

impl CallEventHub {
    pub(crate) fn new(redis: redis::Client) -> Self {
        let hub = Self {
            senders: Arc::new(RwLock::new(HashMap::new())),
            redis,
            origin: Uuid::new_v4(),
        };
        hub.start_subscriber();
        hub
    }

    async fn subscribe(&self, aci: Uuid) -> broadcast::Receiver<String> {
        let mut senders = self.senders.write().await;
        senders
            .entry(aci)
            .or_insert_with(|| broadcast::channel(128).0)
            .subscribe()
    }

    async fn notify(&self, aci: Uuid, call_id: Uuid, event_type: &str) {
        let event = serde_json::json!({
            "protocolVersion": 1,
            "callId": call_id,
            "type": event_type,
        })
        .to_string();
        self.notify_local(aci, &event).await;
        let payload = serde_json::json!({
            "origin": self.origin,
            "recipient": aci,
            "event": event,
        })
        .to_string();
        if let Ok(mut connection) = self.redis.get_multiplexed_async_connection().await {
            let _: redis::RedisResult<i64> = redis::cmd("PUBLISH")
                .arg(CALL_EVENT_REDIS_CHANNEL)
                .arg(payload)
                .query_async(&mut connection)
                .await;
        }
    }

    async fn notify_local(&self, aci: Uuid, event: &str) {
        let senders = self.senders.read().await;
        if let Some(sender) = senders.get(&aci) {
            let _ = sender.send(event.to_owned());
        }
    }

    fn start_subscriber(&self) {
        let hub = self.clone();
        tokio::spawn(async move {
            loop {
                if let Ok(mut pubsub) = hub.redis.get_async_pubsub().await {
                    if pubsub.subscribe(CALL_EVENT_REDIS_CHANNEL).await.is_ok() {
                        let mut messages = pubsub.on_message();
                        while let Some(message) = messages.next().await {
                            let Ok(raw) = message.get_payload::<String>() else {
                                continue;
                            };
                            let Ok(value) = serde_json::from_str::<serde_json::Value>(&raw) else {
                                continue;
                            };
                            let Some(origin) = value.get("origin").and_then(|item| item.as_str())
                            else {
                                continue;
                            };
                            if origin == hub.origin.to_string() {
                                continue;
                            }
                            let Some(recipient) =
                                value.get("recipient").and_then(|item| item.as_str())
                            else {
                                continue;
                            };
                            let Some(event) = value.get("event").and_then(|item| item.as_str())
                            else {
                                continue;
                            };
                            if let Ok(aci) = Uuid::parse_str(recipient) {
                                hub.notify_local(aci, event).await;
                            }
                        }
                    }
                }
                tokio::time::sleep(std::time::Duration::from_secs(1)).await;
            }
        });
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CallCapabilities {
    call_protocol: CallProtocolVersion,
    enabled: bool,
    maximum_participants: u8,
    media_ready: bool,
    media_provider: &'static str,
    features: [&'static str; 4],
}

#[derive(Debug, Serialize)]
struct CallProtocolVersion {
    major: u8,
    minor: u8,
}

pub(crate) async fn capabilities(State(state): State<AppState>) -> Json<CallCapabilities> {
    let ready = match state.call_config.as_ref() {
        Some(config) => config.media_ready().await,
        None => false,
    };
    Json(CallCapabilities {
        call_protocol: CallProtocolVersion { major: 1, minor: 0 },
        enabled: ready,
        maximum_participants: 8,
        media_ready: ready,
        media_provider: "livekit-self-hosted",
        features: ["e2ee", "group-calls", "first-answer-wins", "sos-preemption"],
    })
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CreateCallRequest {
    idempotency_key: String,
    conversation_id: Uuid,
    invitees: Vec<Uuid>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AddParticipantsRequest {
    invitees: Vec<Uuid>,
    #[serde(default)]
    confirm_create_private_group: bool,
    #[serde(default)]
    display_name: String,
}

#[derive(Debug, Default, Deserialize)]
pub(crate) struct EndCallRequest {
    #[serde(default)]
    reason: Option<String>,
}

#[derive(Debug, Serialize, sqlx::FromRow)]
#[serde(rename_all = "camelCase")]
struct CallRow {
    call_id: Uuid,
    conversation_id: Uuid,
    host_aci: Uuid,
    state: String,
    call_epoch: i32,
    participant_limit: i32,
    created_at: DateTime<Utc>,
    ringing_expires_at: DateTime<Utc>,
    activated_at: Option<DateTime<Utc>>,
    ended_at: Option<DateTime<Utc>>,
    end_reason: Option<String>,
    #[serde(skip)]
    livekit_room_name: String,
}

#[derive(Debug, Serialize, sqlx::FromRow)]
#[serde(rename_all = "camelCase")]
struct ParticipantRow {
    aci: Uuid,
    claimed_device_id: Option<i32>,
    state: String,
    join_order: i32,
    invited_at: DateTime<Utc>,
    answered_at: Option<DateTime<Utc>>,
    joined_at: Option<DateTime<Utc>>,
    left_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CallResponse {
    #[serde(flatten)]
    call: CallRow,
    requester_is_host: bool,
    participants: Vec<ParticipantRow>,
    e2ee_required: bool,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AnswerResponse {
    call_id: Uuid,
    server_url: String,
    participant_identity: String,
    join_token: String,
    expires_in_seconds: u16,
    e2ee_required: bool,
    call_epoch: i32,
}

#[derive(Serialize)]
struct LiveKitClaims<'a> {
    iss: &'a str,
    sub: &'a str,
    aud: &'a str,
    nbf: i64,
    exp: i64,
    video: LiveKitVideoGrant<'a>,
}

#[derive(Debug, sqlx::FromRow)]
struct MediaActionRow {
    action_id: Uuid,
    action_type: String,
    livekit_room_name: String,
    livekit_identity: String,
}

#[derive(Debug, Deserialize)]
struct LiveKitWebhookClaims {
    sha256: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct LiveKitWebhookEvent {
    event: String,
    id: String,
    room: Option<LiveKitWebhookRoom>,
    participant: Option<LiveKitWebhookParticipant>,
}

#[derive(Debug, Deserialize)]
struct LiveKitWebhookRoom {
    name: String,
}

#[derive(Debug, Deserialize)]
struct LiveKitWebhookParticipant {
    identity: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct LiveKitVideoGrant<'a> {
    room_join: bool,
    room: &'a str,
    can_publish: bool,
    can_subscribe: bool,
    can_publish_data: bool,
    room_create: bool,
    room_admin: bool,
    room_record: bool,
}

/// Signature-verified LiveKit room events. This route deliberately accepts no
/// device credential; possession of the LiveKit API signing secret is the only
/// authority and the raw body digest is authenticated by the webhook JWT.
pub(crate) async fn livekit_webhook(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<StatusCode, ApiError> {
    let config = require_call_config(&state)?;
    config.verify_webhook(&headers, &body)?;
    let event: LiveKitWebhookEvent =
        serde_json::from_slice(&body).map_err(|_| ApiError::bad_request("INVALID_WEBHOOK_BODY"))?;
    if event.id.len() < 8 || event.id.len() > 128 {
        return Err(ApiError::bad_request("INVALID_WEBHOOK_EVENT"));
    }
    let room_name = event
        .room
        .as_ref()
        .map(|room| room.name.as_str())
        .filter(|name| !name.is_empty());
    let Some(room_name) = room_name else {
        // Events unrelated to a room do not affect the call state machine.
        return Ok(StatusCode::OK);
    };
    let call_id: Option<Uuid> =
        sqlx::query_scalar("SELECT call_id FROM call_sessions WHERE livekit_room_name=$1")
            .bind(room_name)
            .fetch_optional(&state.pool)
            .await?;
    let Some(call_id) = call_id else {
        // The media cluster may serve other applications; never reveal whether
        // a signed opaque room name belongs to PTT Talk.
        return Ok(StatusCode::OK);
    };

    let mut tx = state.pool.begin().await?;
    let inserted = sqlx::query(
        "INSERT INTO livekit_webhook_events(event_id,call_id) VALUES($1,$2) ON CONFLICT DO NOTHING",
    )
    .bind(&event.id)
    .bind(call_id)
    .execute(&mut *tx)
    .await?
    .rows_affected();
    if inserted == 0 {
        tx.commit().await?;
        return Ok(StatusCode::OK);
    }

    let mut notification = None;
    match event.event.as_str() {
        "participant_joined" => {
            let identity = event
                .participant
                .as_ref()
                .map(|participant| participant.identity.as_str())
                .filter(|identity| !identity.is_empty())
                .ok_or_else(|| ApiError::bad_request("INVALID_WEBHOOK_EVENT"))?;
            let joined: Option<Uuid> = sqlx::query_scalar(
                "UPDATE call_participants SET state='joined',joined_at=COALESCE(joined_at,now()) WHERE call_id=$1 AND livekit_identity=$2 AND state='connecting' RETURNING aci",
            )
            .bind(call_id)
            .bind(identity)
            .fetch_optional(&mut *tx)
            .await?;
            if joined.is_some() {
                let joined_count: i64 = sqlx::query_scalar(
                    "SELECT count(*) FROM call_participants WHERE call_id=$1 AND state='joined'",
                )
                .bind(call_id)
                .fetch_one(&mut *tx)
                .await?;
                if joined_count >= 2 {
                    sqlx::query("UPDATE call_sessions SET state='active',activated_at=COALESCE(activated_at,now()),last_key_rotation_at=now() WHERE call_id=$1 AND state IN ('ringing','connecting')")
                        .bind(call_id).execute(&mut *tx).await?;
                }
                coordination_event(&mut tx, call_id, "roster_changed").await?;
                notification = Some("roster_changed");
            }
        }
        "participant_left" | "participant_connection_aborted" => {
            let identity = event
                .participant
                .as_ref()
                .map(|participant| participant.identity.as_str())
                .filter(|identity| !identity.is_empty())
                .ok_or_else(|| ApiError::bad_request("INVALID_WEBHOOK_EVENT"))?;
            let departed: Option<Uuid> = sqlx::query_scalar(
                "UPDATE call_participants SET state=CASE WHEN $3='participant_connection_aborted' THEN 'failed' ELSE 'left' END,left_at=COALESCE(left_at,now()) WHERE call_id=$1 AND livekit_identity=$2 AND state IN ('connecting','joined') RETURNING aci",
            )
            .bind(call_id)
            .bind(identity)
            .bind(&event.event)
            .fetch_optional(&mut *tx)
            .await?;
            if let Some(aci) = departed {
                rotate_epoch(&mut tx, call_id).await?;
                let host: Uuid =
                    sqlx::query_scalar("SELECT host_aci FROM call_sessions WHERE call_id=$1")
                        .bind(call_id)
                        .fetch_one(&mut *tx)
                        .await?;
                if host == aci {
                    transfer_host_or_end(&mut tx, call_id).await?;
                }
                finish_if_empty(&mut tx, call_id).await?;
                notification = Some("roster_changed");
            }
        }
        "room_finished" => {
            finish_call(&mut tx, call_id, "completed").await?;
            notification = Some("ended");
        }
        "room_started" | "track_published" | "track_unpublished" => {}
        _ => {}
    }
    tx.commit().await?;
    if let Some(event_type) = notification {
        notify_roster(&state, call_id, event_type).await?;
    }
    Ok(StatusCode::OK)
}

pub(crate) async fn create(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<CreateCallRequest>,
) -> Result<impl IntoResponse, ApiError> {
    if !require_call_config(&state)?.media_ready().await {
        return Err(ApiError::unavailable("CALL_MEDIA_NOT_READY"));
    }
    let principal = require_device(&state.pool, &headers).await?;
    validate_create(&request, principal)?;
    require_membership(&state.pool, principal.aci, request.conversation_id).await?;
    let conversation_kind: String =
        sqlx::query_scalar("SELECT kind FROM channels WHERE channel_id=$1")
            .bind(request.conversation_id)
            .fetch_one(&state.pool)
            .await?;
    if (conversation_kind == "direct" && request.invitees.len() != 1)
        || (conversation_kind != "direct" && request.invitees.len() < 2)
    {
        return Err(ApiError::bad_request("INVALID_CALL_PARTICIPANTS"));
    }
    let idempotency_hash = Sha256::digest(request.idempotency_key.as_bytes());
    if let Some(existing) = sqlx::query_as::<_, CallRow>(&format!(
        "{} WHERE host_aci=$1 AND idempotency_key_sha256=$2",
        call_select()
    ))
    .bind(principal.aci)
    .bind(idempotency_hash.as_slice())
    .fetch_optional(&state.pool)
    .await?
    {
        return Ok((
            axum::http::StatusCode::OK,
            Json(call_response(&state.pool, existing, principal.aci).await?),
        ));
    }
    let busy: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM call_participants WHERE aci=$1 AND state IN ('connecting','joined'))",
    )
    .bind(principal.aci)
    .fetch_one(&state.pool)
    .await?;
    if busy {
        return Err(ApiError::conflict("ACCOUNT_ALREADY_IN_CALL"));
    }
    let eligible: Vec<Uuid> = sqlx::query_scalar(
        "SELECT aci FROM memberships WHERE channel_id=$1 AND left_epoch IS NULL AND aci=ANY($2)",
    )
    .bind(request.conversation_id)
    .bind(&request.invitees)
    .fetch_all(&state.pool)
    .await?;
    if eligible.len() != request.invitees.len() {
        return Err(ApiError::forbidden_code("CALL_INVITEE_NOT_ELIGIBLE"));
    }

    let call_id = Uuid::new_v4();
    let created_at = Utc::now();
    let mut tx = state.pool.begin().await?;
    sqlx::query(
        "INSERT INTO call_sessions(call_id,conversation_id,host_aci,state,call_epoch,participant_limit,idempotency_key_sha256,livekit_room_name,created_at,ringing_expires_at,coordination_expires_at) VALUES($1,$2,$3,'ringing',1,8,$4,$5,$6,$7,$8)",
    )
    .bind(call_id)
    .bind(request.conversation_id)
    .bind(principal.aci)
    .bind(idempotency_hash.as_slice())
    .bind(random_opaque_id())
    .bind(created_at)
    .bind(created_at + Duration::seconds(CALL_RING_SECONDS))
    .bind(created_at + Duration::seconds(CALL_MAX_SECONDS + 24 * 60 * 60))
    .execute(&mut *tx)
    .await?;
    sqlx::query("INSERT INTO call_participants(call_id,aci,claimed_device_id,livekit_identity,state,join_order,invited_by,invited_at,answered_at) VALUES($1,$2,$3,$4,'connecting',1,$2,$5,$5)")
        .bind(call_id).bind(principal.aci).bind(principal.device_id).bind(random_opaque_id()).bind(created_at)
        .execute(&mut *tx).await.map_err(call_seat_error)?;
    for (index, invitee) in request.invitees.iter().enumerate() {
        sqlx::query("INSERT INTO call_participants(call_id,aci,state,join_order,invited_by,invited_at) VALUES($1,$2,'ringing',$3,$4,$5)")
            .bind(call_id).bind(invitee).bind(index as i32 + 2).bind(principal.aci).bind(created_at)
            .execute(&mut *tx).await?;
    }
    coordination_event(&mut tx, call_id, "ringing").await?;
    enqueue_call_pushes(&mut tx, call_id, &request.invitees).await?;
    tx.commit().await?;
    for invitee in request.invitees {
        state.call_events.notify(invitee, call_id, "ringing").await;
    }
    let row = load_call(&state.pool, call_id).await?;
    Ok((
        axum::http::StatusCode::CREATED,
        Json(call_response(&state.pool, row, principal.aci).await?),
    ))
}

pub(crate) async fn get(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(call_id): Path<Uuid>,
) -> Result<Json<CallResponse>, ApiError> {
    let principal = require_device(&state.pool, &headers).await?;
    let call = authorized_call(&state.pool, call_id, principal.aci).await?;
    Ok(Json(call_response(&state.pool, call, principal.aci).await?))
}

pub(crate) async fn answer(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(call_id): Path<Uuid>,
) -> Result<Json<AnswerResponse>, ApiError> {
    let config = require_call_config(&state)?.clone();
    if !config.media_ready().await {
        return Err(ApiError::unavailable("CALL_MEDIA_NOT_READY"));
    }
    let principal = require_device(&state.pool, &headers).await?;
    let mut tx = state.pool.begin().await?;
    let call = authorized_call_for_update(&mut tx, call_id, principal.aci).await?;
    if call.state == "ended" {
        return Err(ApiError::conflict("CALL_ENDED"));
    }
    if call.activated_at.is_none() && call.ringing_expires_at <= Utc::now() {
        finish_call(&mut tx, call_id, "missed").await?;
        tx.commit().await?;
        return Err(ApiError::gone("CALL_EXPIRED"));
    }
    let participant: (Option<i32>, Option<String>, String) = sqlx::query_as(
        "SELECT claimed_device_id,livekit_identity,state FROM call_participants WHERE call_id=$1 AND aci=$2 FOR UPDATE",
    )
    .bind(call_id)
    .bind(principal.aci)
    .fetch_one(&mut *tx)
    .await?;
    if participant
        .0
        .is_some_and(|device| device != principal.device_id)
    {
        return Err(ApiError::conflict("CALL_ANSWERED_ELSEWHERE"));
    }
    let identity = participant.1.unwrap_or_else(random_opaque_id);
    let claimed_now = participant.0.is_none();
    if claimed_now && !matches!(participant.2.as_str(), "invited" | "ringing") {
        return Err(ApiError::conflict("CALL_PARTICIPANT_NOT_ELIGIBLE"));
    }
    let rejoining = participant.0 == Some(principal.device_id)
        && matches!(participant.2.as_str(), "left" | "failed");
    if !claimed_now && !rejoining && !matches!(participant.2.as_str(), "connecting" | "joined") {
        return Err(ApiError::conflict("CALL_PARTICIPANT_NOT_ELIGIBLE"));
    }
    if claimed_now {
        let updated = sqlx::query("UPDATE call_participants SET claimed_device_id=$1,livekit_identity=$2,state='connecting',answered_at=now(),joined_at=NULL,left_at=NULL WHERE call_id=$3 AND aci=$4 AND claimed_device_id IS NULL AND state IN ('invited','ringing')")
            .bind(principal.device_id).bind(&identity).bind(call_id).bind(principal.aci)
            .execute(&mut *tx).await.map_err(call_seat_error)?;
        if updated.rows_affected() != 1 {
            return Err(ApiError::conflict("CALL_ANSWERED_ELSEWHERE"));
        }
    } else if rejoining {
        let updated = sqlx::query("UPDATE call_participants SET state='connecting',answered_at=now(),joined_at=NULL,left_at=NULL WHERE call_id=$1 AND aci=$2 AND claimed_device_id=$3 AND state IN ('left','failed')")
            .bind(call_id).bind(principal.aci).bind(principal.device_id)
            .execute(&mut *tx).await.map_err(call_seat_error)?;
        if updated.rows_affected() != 1 {
            return Err(ApiError::conflict("CALL_PARTICIPANT_NOT_ELIGIBLE"));
        }
    }
    sqlx::query("UPDATE call_sessions SET state=CASE WHEN state='ringing' THEN 'connecting' ELSE state END WHERE call_id=$1 AND state<>'ended'")
        .bind(call_id).execute(&mut *tx).await?;
    let call_epoch = if claimed_now || rejoining {
        rotate_epoch(&mut tx, call_id).await?;
        sqlx::query_scalar("SELECT call_epoch FROM call_sessions WHERE call_id=$1")
            .bind(call_id)
            .fetch_one(&mut *tx)
            .await?
    } else {
        call.call_epoch
    };
    if claimed_now {
        coordination_event(&mut tx, call_id, "answered").await?;
    }
    tx.commit().await?;
    if claimed_now || rejoining {
        notify_roster(
            &state,
            call_id,
            if claimed_now {
                "answered"
            } else {
                "roster_changed"
            },
        )
        .await?;
    }
    Ok(Json(AnswerResponse {
        call_id,
        server_url: config.public_url.to_string(),
        participant_identity: identity.clone(),
        join_token: config.token(&call.livekit_room_name, &identity)?,
        expires_in_seconds: 300,
        e2ee_required: true,
        call_epoch,
    }))
}

pub(crate) async fn decline(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(call_id): Path<Uuid>,
) -> Result<Json<serde_json::Value>, ApiError> {
    participant_exit(&state, &headers, call_id, "declined").await
}

pub(crate) async fn leave(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(call_id): Path<Uuid>,
) -> Result<Json<serde_json::Value>, ApiError> {
    participant_exit(&state, &headers, call_id, "left").await
}

pub(crate) async fn end(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(call_id): Path<Uuid>,
    Json(request): Json<EndCallRequest>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let principal = require_device(&state.pool, &headers).await?;
    let call = authorized_call(&state.pool, call_id, principal.aci).await?;
    if call.state == "ended" {
        return Ok(Json(serde_json::json!({"accepted":true})));
    }
    require_active_call_seat(&state.pool, call_id, principal).await?;
    let reason = if request.reason.as_deref() == Some("sos_preempted") {
        "sos_preempted"
    } else if call.activated_at.is_none() {
        "cancelled"
    } else {
        "host_ended"
    };
    if reason != "sos_preempted" && call.host_aci != principal.aci {
        return Err(ApiError::forbidden_code("CALL_HOST_REQUIRED"));
    }
    let mut tx = state.pool.begin().await?;
    finish_call(&mut tx, call_id, reason).await?;
    tx.commit().await?;
    process_media_actions(&state, 10).await?;
    notify_roster(&state, call_id, "ended").await?;
    Ok(Json(serde_json::json!({"accepted":true})))
}

pub(crate) async fn add_participants(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(call_id): Path<Uuid>,
    Json(request): Json<AddParticipantsRequest>,
) -> Result<Json<CallResponse>, ApiError> {
    let principal = require_device(&state.pool, &headers).await?;
    let call = authorized_call(&state.pool, call_id, principal.aci).await?;
    if call.host_aci != principal.aci || call.state == "ended" {
        return Err(ApiError::forbidden_code("CALL_HOST_REQUIRED"));
    }
    require_active_call_seat(&state.pool, call_id, principal).await?;
    validate_invitees(&request.invitees, principal.aci)?;
    let mut tx = state.pool.begin().await?;
    sqlx::query("SELECT 1 FROM call_sessions WHERE call_id=$1 FOR UPDATE")
        .bind(call_id)
        .execute(&mut *tx)
        .await?;
    let current: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM call_participants WHERE call_id=$1 AND state IN ('invited','ringing','connecting','joined')",
    )
    .bind(call_id)
    .fetch_one(&mut *tx)
    .await?;
    if current + request.invitees.len() as i64 > 8 {
        return Err(ApiError::conflict("CALL_PARTICIPANT_LIMIT"));
    }
    let already_present: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM call_participants WHERE call_id=$1 AND aci=ANY($2) AND state IN ('invited','ringing','connecting','joined'))",
    )
    .bind(call_id)
    .bind(&request.invitees)
    .fetch_one(&mut *tx)
    .await?;
    if already_present {
        return Err(ApiError::conflict("CALL_PARTICIPANT_ALREADY_PRESENT"));
    }
    let conversation_kind: String =
        sqlx::query_scalar("SELECT kind FROM channels WHERE channel_id=$1 FOR UPDATE")
            .bind(call.conversation_id)
            .fetch_one(&mut *tx)
            .await?;
    let active_accounts: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM accounts WHERE aci=ANY($1) AND disabled_at IS NULL AND account_kind IN ('member','guest') AND (guest_expires_at IS NULL OR guest_expires_at>now())",
    )
    .bind(&request.invitees)
    .fetch_one(&mut *tx)
    .await?;
    if active_accounts != request.invitees.len() as i64 {
        return Err(ApiError::forbidden_code("CALL_INVITEE_NOT_ELIGIBLE"));
    }

    if conversation_kind == "direct" {
        if !request.confirm_create_private_group {
            return Err(ApiError::conflict("CALL_GROUP_CONFIRMATION_REQUIRED"));
        }
        let members: Vec<Uuid> = sqlx::query_scalar(
            "SELECT aci FROM call_participants WHERE call_id=$1 AND state IN ('invited','ringing','connecting','joined') UNION SELECT unnest($2::uuid[])",
        )
        .bind(call_id)
        .bind(&request.invitees)
        .fetch_all(&mut *tx)
        .await?;
        if !(3..=8).contains(&members.len()) {
            return Err(ApiError::bad_request("INVALID_CONVERSATION_MEMBERS"));
        }
        let requested_name = request.display_name.trim();
        let display_name = if requested_name.is_empty() {
            sqlx::query_scalar::<_, String>(
                "SELECT left(string_agg(display_name, ', ' ORDER BY lower(display_name)),80) FROM accounts WHERE aci=ANY($1)",
            )
            .bind(&members)
            .fetch_one(&mut *tx)
            .await?
        } else {
            if requested_name.chars().count() > 80 {
                return Err(ApiError::bad_request("INVALID_CONVERSATION_NAME"));
            }
            requested_name.to_owned()
        };
        let created = Uuid::new_v4();
        sqlx::query("INSERT INTO channels(channel_id,display_name,kind,distribution_id,retention_days,created_by) VALUES($1,$2,'adhoc',$3,30,$4)")
            .bind(created).bind(display_name).bind(Uuid::new_v4()).bind(principal.aci)
            .execute(&mut *tx).await?;
        for member in members {
            sqlx::query(
                "INSERT INTO memberships(channel_id,aci,role,joined_epoch) VALUES($1,$2,'talk',1)",
            )
            .bind(created)
            .bind(member)
            .execute(&mut *tx)
            .await?;
        }
        sqlx::query("UPDATE call_sessions SET conversation_id=$1 WHERE call_id=$2")
            .bind(created)
            .bind(call_id)
            .execute(&mut *tx)
            .await?;
    } else if conversation_kind == "adhoc" {
        let next_epoch: i32 = sqlx::query_scalar(
            "UPDATE channels SET membership_epoch=membership_epoch+1,distribution_id=$1 WHERE channel_id=$2 RETURNING membership_epoch",
        )
        .bind(Uuid::new_v4())
        .bind(call.conversation_id)
        .fetch_one(&mut *tx)
        .await?;
        for invitee in &request.invitees {
            sqlx::query("INSERT INTO memberships(channel_id,aci,role,joined_epoch,left_epoch) VALUES($1,$2,'talk',$3,NULL) ON CONFLICT(channel_id,aci) DO UPDATE SET role='talk',joined_epoch=$3,left_epoch=NULL")
                .bind(call.conversation_id).bind(invitee).bind(next_epoch)
                .execute(&mut *tx).await?;
        }
    } else {
        let eligible: Vec<Uuid> = sqlx::query_scalar(
            "SELECT aci FROM memberships WHERE channel_id=$1 AND left_epoch IS NULL AND aci=ANY($2)",
        )
        .bind(call.conversation_id)
        .bind(&request.invitees)
        .fetch_all(&mut *tx)
        .await?;
        if eligible.len() != request.invitees.len() {
            return Err(ApiError::forbidden_code("CALL_INVITEE_NOT_ELIGIBLE"));
        }
    }
    // The call_sessions row is locked above and serializes every roster
    // addition for this call. PostgreSQL forbids FOR UPDATE on an aggregate,
    // so do not try to apply a second, invalid lock to max(join_order).
    let maximum: i32 = sqlx::query_scalar(
        "SELECT COALESCE(max(join_order),0) FROM call_participants WHERE call_id=$1",
    )
    .bind(call_id)
    .fetch_one(&mut *tx)
    .await?;
    for (offset, invitee) in request.invitees.iter().enumerate() {
        sqlx::query("INSERT INTO call_participants(call_id,aci,state,join_order,invited_by,invited_at) VALUES($1,$2,'ringing',$3,$4,now()) ON CONFLICT(call_id,aci) DO UPDATE SET claimed_device_id=NULL,livekit_identity=NULL,state='ringing',join_order=$3,invited_by=$4,invited_at=now(),answered_at=NULL,joined_at=NULL,left_at=NULL")
            .bind(call_id).bind(invitee).bind(maximum + offset as i32 + 1).bind(principal.aci)
            .execute(&mut *tx).await?;
    }
    rotate_epoch(&mut tx, call_id).await?;
    enqueue_call_pushes(&mut tx, call_id, &request.invitees).await?;
    tx.commit().await?;
    for invitee in &request.invitees {
        state.call_events.notify(*invitee, call_id, "ringing").await;
    }
    Ok(Json(
        call_response(
            &state.pool,
            load_call(&state.pool, call_id).await?,
            principal.aci,
        )
        .await?,
    ))
}

pub(crate) async fn remove_participant(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path((call_id, aci)): Path<(Uuid, Uuid)>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let principal = require_device(&state.pool, &headers).await?;
    let call = authorized_call(&state.pool, call_id, principal.aci).await?;
    if call.host_aci != principal.aci || call.state == "ended" || aci == principal.aci {
        return Err(ApiError::forbidden_code("CALL_HOST_REQUIRED"));
    }
    require_active_call_seat(&state.pool, call_id, principal).await?;
    let mut tx = state.pool.begin().await?;
    let removed_identity: Option<Option<String>> = sqlx::query_scalar(
        "UPDATE call_participants SET state='removed',left_at=now() WHERE call_id=$1 AND aci=$2 AND state NOT IN ('removed','left','declined','missed') RETURNING livekit_identity",
    )
    .bind(call_id)
    .bind(aci)
    .fetch_optional(&mut *tx)
    .await?;
    if removed_identity.is_none() {
        return Err(ApiError::not_found("CALL_PARTICIPANT_NOT_FOUND"));
    }
    if let Some(identity) = removed_identity.as_ref().and_then(|value| value.as_deref()) {
        enqueue_media_action(&mut tx, call_id, "remove_participant", identity).await?;
    }
    rotate_epoch(&mut tx, call_id).await?;
    tx.commit().await?;
    process_media_actions(&state, 10).await?;
    notify_roster(&state, call_id, "roster_changed").await?;
    Ok(Json(serde_json::json!({"accepted":true})))
}

pub(crate) async fn events(
    State(state): State<AppState>,
    headers: HeaderMap,
    upgrade: WebSocketUpgrade,
) -> Result<Response, ApiError> {
    let principal = require_device(&state.pool, &headers).await?;
    let mut receiver = state.call_events.subscribe(principal.aci).await;
    Ok(upgrade.on_upgrade(move |mut socket| async move {
        loop {
            match receiver.recv().await {
                Ok(event) => {
                    if socket.send(Message::Text(event.into())).await.is_err() {
                        break;
                    }
                }
                Err(broadcast::error::RecvError::Lagged(_)) => continue,
                Err(broadcast::error::RecvError::Closed) => break,
            }
        }
    }))
}

async fn participant_exit(
    state: &AppState,
    headers: &HeaderMap,
    call_id: Uuid,
    next: &str,
) -> Result<Json<serde_json::Value>, ApiError> {
    let principal = require_device(&state.pool, headers).await?;
    let call = authorized_call(&state.pool, call_id, principal.aci).await?;
    let participant: (Option<i32>, String) = sqlx::query_as(
        "SELECT claimed_device_id,state FROM call_participants WHERE call_id=$1 AND aci=$2",
    )
    .bind(call_id)
    .bind(principal.aci)
    .fetch_one(&state.pool)
    .await?;
    match next {
        "left" => {
            if participant.0 != Some(principal.device_id) {
                return Err(ApiError::conflict("CALL_ACTIVE_DEVICE_REQUIRED"));
            }
            if participant.1 == "left" {
                return Ok(Json(serde_json::json!({"accepted":true})));
            }
            if !matches!(participant.1.as_str(), "connecting" | "joined" | "failed") {
                return Err(ApiError::conflict("INVALID_CALL_TRANSITION"));
            }
        }
        "declined" => {
            if participant.1 == "declined" {
                return Ok(Json(serde_json::json!({"accepted":true})));
            }
            if participant.0.is_some() || !matches!(participant.1.as_str(), "invited" | "ringing") {
                return Err(ApiError::conflict("INVALID_CALL_TRANSITION"));
            }
        }
        _ => return Err(ApiError::bad_request("INVALID_CALL_TRANSITION")),
    }
    let mut tx = state.pool.begin().await?;
    let updated = sqlx::query("UPDATE call_participants SET state=$1,left_at=now() WHERE call_id=$2 AND aci=$3 AND state NOT IN ('declined','left','removed','missed')")
        .bind(next).bind(call_id).bind(principal.aci).execute(&mut *tx).await?;
    if updated.rows_affected() > 0 {
        rotate_epoch(&mut tx, call_id).await?;
    }
    if next == "left" && call.host_aci == principal.aci {
        transfer_host_or_end(&mut tx, call_id).await?;
    }
    if next == "declined" && call.activated_at.is_none() {
        let remaining_invitees: i64 = sqlx::query_scalar(
            "SELECT count(*) FROM call_participants WHERE call_id=$1 AND aci<>$2 AND state IN ('invited','ringing','connecting','joined')",
        )
        .bind(call_id)
        .bind(call.host_aci)
        .fetch_one(&mut *tx)
        .await?;
        if remaining_invitees == 0 {
            finish_call(&mut tx, call_id, "declined").await?;
        }
    }
    finish_if_empty(&mut tx, call_id).await?;
    tx.commit().await?;
    notify_roster(state, call_id, "roster_changed").await?;
    Ok(Json(serde_json::json!({"accepted":true})))
}

fn validate_create(
    request: &CreateCallRequest,
    principal: AuthenticatedDevice,
) -> Result<(), ApiError> {
    if request.idempotency_key.len() < 16 || request.idempotency_key.len() > 128 {
        return Err(ApiError::bad_request("INVALID_IDEMPOTENCY_KEY"));
    }
    validate_invitees(&request.invitees, principal.aci)
}

fn call_seat_error(error: sqlx::Error) -> ApiError {
    let is_seat_conflict = error.as_database_error().is_some_and(|database| {
        database.code().as_deref() == Some("23505")
            && database.constraint() == Some("call_participants_one_live_account_seat")
    });
    if is_seat_conflict {
        ApiError::conflict("ACCOUNT_ALREADY_IN_CALL")
    } else {
        error.into()
    }
}

fn validate_invitees(invitees: &[Uuid], principal: Uuid) -> Result<(), ApiError> {
    let unique: std::collections::HashSet<_> = invitees.iter().collect();
    if invitees.is_empty()
        || invitees.len() > 7
        || unique.len() != invitees.len()
        || invitees.contains(&principal)
    {
        return Err(ApiError::bad_request("INVALID_INVITEES"));
    }
    Ok(())
}

fn require_call_config(state: &AppState) -> Result<&CallConfig, ApiError> {
    state
        .call_config
        .as_ref()
        .ok_or_else(|| ApiError::unavailable("CALL_MEDIA_NOT_READY"))
}

async fn require_membership(
    pool: &PgPool,
    aci: Uuid,
    conversation_id: Uuid,
) -> Result<(), ApiError> {
    let active: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM memberships WHERE aci=$1 AND channel_id=$2 AND left_epoch IS NULL)")
        .bind(aci).bind(conversation_id).fetch_one(pool).await?;
    if active {
        Ok(())
    } else {
        Err(ApiError::forbidden())
    }
}

async fn require_active_call_seat(
    pool: &PgPool,
    call_id: Uuid,
    principal: AuthenticatedDevice,
) -> Result<(), ApiError> {
    let active: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM call_participants WHERE call_id=$1 AND aci=$2 AND claimed_device_id=$3 AND state IN ('connecting','joined'))",
    )
    .bind(call_id)
    .bind(principal.aci)
    .bind(principal.device_id)
    .fetch_one(pool)
    .await?;
    if active {
        Ok(())
    } else {
        Err(ApiError::conflict("CALL_ACTIVE_DEVICE_REQUIRED"))
    }
}

fn call_select() -> &'static str {
    "SELECT call_id,conversation_id,host_aci,state,call_epoch,participant_limit,created_at,ringing_expires_at,activated_at,ended_at,end_reason,livekit_room_name FROM call_sessions"
}

async fn load_call(pool: &PgPool, call_id: Uuid) -> Result<CallRow, ApiError> {
    sqlx::query_as::<_, CallRow>(&format!("{} WHERE call_id=$1", call_select()))
        .bind(call_id)
        .fetch_optional(pool)
        .await?
        .ok_or_else(|| ApiError::not_found("CALL_NOT_FOUND"))
}

async fn authorized_call(pool: &PgPool, call_id: Uuid, aci: Uuid) -> Result<CallRow, ApiError> {
    sqlx::query_as::<_, CallRow>(&format!("{} c WHERE c.call_id=$1 AND EXISTS(SELECT 1 FROM call_participants p WHERE p.call_id=c.call_id AND p.aci=$2 AND p.state<>'removed')", call_select()))
        .bind(call_id).bind(aci).fetch_optional(pool).await?.ok_or_else(|| ApiError::not_found("CALL_NOT_FOUND"))
}

async fn authorized_call_for_update(
    tx: &mut Transaction<'_, Postgres>,
    call_id: Uuid,
    aci: Uuid,
) -> Result<CallRow, ApiError> {
    sqlx::query_as::<_, CallRow>(&format!("{} c WHERE c.call_id=$1 AND EXISTS(SELECT 1 FROM call_participants p WHERE p.call_id=c.call_id AND p.aci=$2 AND p.state<>'removed') FOR UPDATE", call_select()))
        .bind(call_id).bind(aci).fetch_optional(&mut **tx).await?.ok_or_else(|| ApiError::not_found("CALL_NOT_FOUND"))
}

async fn call_response(
    pool: &PgPool,
    call: CallRow,
    requester: Uuid,
) -> Result<CallResponse, ApiError> {
    let participants = sqlx::query_as::<_, ParticipantRow>("SELECT aci,claimed_device_id,state,join_order,invited_at,answered_at,joined_at,left_at FROM call_participants WHERE call_id=$1 ORDER BY join_order")
        .bind(call.call_id).fetch_all(pool).await?;
    Ok(CallResponse {
        requester_is_host: call.host_aci == requester,
        call,
        participants,
        e2ee_required: true,
    })
}

async fn coordination_event(
    tx: &mut Transaction<'_, Postgres>,
    call_id: Uuid,
    event_type: &str,
) -> Result<(), ApiError> {
    sqlx::query("INSERT INTO call_coordination_events(call_id,recipient_aci,event_type,created_at) VALUES($1,NULL,$2,now())")
        .bind(call_id).bind(event_type).execute(&mut **tx).await?;
    Ok(())
}

async fn rotate_epoch(tx: &mut Transaction<'_, Postgres>, call_id: Uuid) -> Result<(), ApiError> {
    sqlx::query(
        "UPDATE call_sessions SET call_epoch=call_epoch+1,last_key_rotation_at=now() WHERE call_id=$1 AND state<>'ended'",
    )
    .bind(call_id)
    .execute(&mut **tx)
    .await?;
    coordination_event(tx, call_id, "roster_changed").await
}

async fn finish_call(
    tx: &mut Transaction<'_, Postgres>,
    call_id: Uuid,
    reason: &str,
) -> Result<(), ApiError> {
    let updated = sqlx::query("UPDATE call_sessions SET state='ended',end_reason=$1,ended_at=now(),coordination_expires_at=now()+interval '24 hours' WHERE call_id=$2 AND state<>'ended'")
        .bind(reason).bind(call_id).execute(&mut **tx).await?;
    if updated.rows_affected() == 0 {
        return Ok(());
    }
    sqlx::query("UPDATE call_participants SET state=CASE WHEN state IN ('ringing','invited') THEN 'missed' WHEN state IN ('joined','connecting') THEN 'left' ELSE state END,left_at=COALESCE(left_at,now()) WHERE call_id=$1")
        .bind(call_id).execute(&mut **tx).await?;
    enqueue_media_action(tx, call_id, "delete_room", "").await?;
    coordination_event(tx, call_id, "ended").await
}

async fn enqueue_media_action(
    tx: &mut Transaction<'_, Postgres>,
    call_id: Uuid,
    action_type: &str,
    livekit_identity: &str,
) -> Result<(), ApiError> {
    sqlx::query(
        "INSERT INTO call_media_actions(action_id,call_id,action_type,livekit_identity) VALUES($1,$2,$3,$4) ON CONFLICT(call_id,action_type,livekit_identity) DO UPDATE SET next_attempt_at=LEAST(call_media_actions.next_attempt_at,now()),completed_at=NULL",
    )
    .bind(Uuid::new_v4())
    .bind(call_id)
    .bind(action_type)
    .bind(livekit_identity)
    .execute(&mut **tx)
    .await?;
    Ok(())
}

async fn process_media_actions(state: &AppState, limit: i64) -> Result<u64, ApiError> {
    let Some(config) = state.call_config.as_ref() else {
        return Ok(0);
    };
    let mut tx = state.pool.begin().await?;
    let actions: Vec<MediaActionRow> = sqlx::query_as(
        "WITH claimed AS (SELECT action_id FROM call_media_actions WHERE completed_at IS NULL AND next_attempt_at<=now() ORDER BY created_at FOR UPDATE SKIP LOCKED LIMIT $1) UPDATE call_media_actions a SET attempts=a.attempts+1,next_attempt_at=now()+LEAST(interval '5 minutes',interval '5 seconds'*power(2,LEAST(a.attempts,6))) FROM claimed WHERE a.action_id=claimed.action_id RETURNING a.action_id,a.action_type,(SELECT livekit_room_name FROM call_sessions WHERE call_id=a.call_id) AS livekit_room_name,a.livekit_identity",
    )
    .bind(limit)
    .fetch_all(&mut *tx)
    .await?;
    tx.commit().await?;

    let mut completed = 0;
    for action in actions {
        match config.perform_media_action(&action).await {
            Ok(()) => {
                sqlx::query("UPDATE call_media_actions SET completed_at=now(),last_error=NULL WHERE action_id=$1")
                    .bind(action.action_id)
                    .execute(&state.pool)
                    .await?;
                completed += 1;
            }
            Err(code) => {
                sqlx::query("UPDATE call_media_actions SET last_error=$1 WHERE action_id=$2")
                    .bind(code)
                    .bind(action.action_id)
                    .execute(&state.pool)
                    .await?;
            }
        }
    }
    Ok(completed)
}

async fn finish_if_empty(
    tx: &mut Transaction<'_, Postgres>,
    call_id: Uuid,
) -> Result<(), ApiError> {
    let active: i64 = sqlx::query_scalar("SELECT count(*) FROM call_participants WHERE call_id=$1 AND state IN ('connecting','joined')")
        .bind(call_id).fetch_one(&mut **tx).await?;
    if active == 0 {
        finish_call(tx, call_id, "completed").await?;
    }
    Ok(())
}

async fn transfer_host_or_end(
    tx: &mut Transaction<'_, Postgres>,
    call_id: Uuid,
) -> Result<(), ApiError> {
    let replacement: Option<Uuid> = sqlx::query_scalar("SELECT aci FROM call_participants WHERE call_id=$1 AND state IN ('connecting','joined') ORDER BY join_order LIMIT 1")
        .bind(call_id).fetch_optional(&mut **tx).await?;
    if let Some(aci) = replacement {
        sqlx::query("UPDATE call_sessions SET host_aci=$1 WHERE call_id=$2")
            .bind(aci)
            .bind(call_id)
            .execute(&mut **tx)
            .await?;
    } else {
        finish_call(tx, call_id, "completed").await?;
    }
    Ok(())
}

async fn enqueue_call_pushes(
    tx: &mut Transaction<'_, Postgres>,
    call_id: Uuid,
    invitees: &[Uuid],
) -> Result<(), ApiError> {
    sqlx::query("DELETE FROM push_outbox WHERE message_id=$1 AND aci=ANY($2) AND kind='call'")
        .bind(call_id)
        .bind(invitees)
        .execute(&mut **tx)
        .await?;
    sqlx::query("INSERT INTO push_outbox(id,message_id,aci,device_id,provider,kind) SELECT gen_random_uuid(),$1,r.aci,r.device_id,r.provider,'call' FROM push_registrations r WHERE r.aci=ANY($2) AND r.provider IN ('fcm','apns-voip','apns-voip-sandbox') ON CONFLICT DO NOTHING")
        .bind(call_id).bind(invitees).execute(&mut **tx).await?;
    Ok(())
}

async fn notify_roster(state: &AppState, call_id: Uuid, event_type: &str) -> Result<(), ApiError> {
    let recipients: Vec<Uuid> = sqlx::query_scalar(
        "SELECT aci FROM call_participants WHERE call_id=$1 AND state<>'removed'",
    )
    .bind(call_id)
    .fetch_all(&state.pool)
    .await?;
    for recipient in recipients {
        state
            .call_events
            .notify(recipient, call_id, event_type)
            .await;
    }
    Ok(())
}

pub(crate) async fn revoke_call_seats(
    tx: &mut Transaction<'_, Postgres>,
    aci: Uuid,
    claimed_device_id: Option<i32>,
) -> Result<Vec<Uuid>, ApiError> {
    let calls: Vec<(Uuid, bool, Option<String>)> = sqlx::query_as(
        "SELECT p.call_id,c.host_aci=p.aci,p.livekit_identity FROM call_participants p JOIN call_sessions c ON c.call_id=p.call_id WHERE p.aci=$1 AND c.state<>'ended' AND p.state IN ('invited','ringing','connecting','joined') AND ($2::integer IS NULL OR p.claimed_device_id=$2) FOR UPDATE OF c,p",
    )
    .bind(aci)
    .bind(claimed_device_id)
    .fetch_all(&mut **tx)
    .await?;
    let mut changed = Vec::with_capacity(calls.len());
    for (call_id, was_host, livekit_identity) in calls {
        sqlx::query("UPDATE call_participants SET state='removed',left_at=now() WHERE call_id=$1 AND aci=$2")
            .bind(call_id).bind(aci).execute(&mut **tx).await?;
        if let Some(identity) = livekit_identity.as_deref() {
            enqueue_media_action(tx, call_id, "remove_participant", identity).await?;
        }
        rotate_epoch(tx, call_id).await?;
        if was_host {
            transfer_host_or_end(tx, call_id).await?;
        }
        finish_if_empty(tx, call_id).await?;
        changed.push(call_id);
    }
    Ok(changed)
}

pub(crate) async fn notify_revoked_call_seats(
    state: &AppState,
    call_ids: &[Uuid],
) -> Result<(), ApiError> {
    process_media_actions(state, 25).await?;
    for call_id in call_ids {
        notify_roster(state, *call_id, "roster_changed").await?;
    }
    Ok(())
}

/// Enforces deadlines independently of client connectivity. Row locks make
/// this safe when every control-plane replica runs the same maintenance loop.
pub(crate) async fn maintenance(state: &AppState) -> Result<u64, ApiError> {
    let mut tx = state.pool.begin().await?;
    let expired: Vec<(Uuid, String)> = sqlx::query_as(
        "SELECT call_id,CASE WHEN activated_at IS NULL THEN 'missed' ELSE 'safety_limit' END FROM call_sessions WHERE state<>'ended' AND ((activated_at IS NULL AND ringing_expires_at<=now()) OR (activated_at IS NOT NULL AND activated_at+interval '8 hours'<=now())) ORDER BY created_at FOR UPDATE SKIP LOCKED LIMIT 100",
    )
    .fetch_all(&mut *tx)
    .await?;
    for (call_id, reason) in &expired {
        finish_call(&mut tx, *call_id, reason).await?;
    }

    // A call can remain active while later invitees are ringing or securing.
    // Expire those per-participant states independently so a missed addition
    // cannot occupy a roster slot forever and an abandoned securing client
    // cannot retain media authorization indefinitely.
    let missed_invites: Vec<Uuid> = sqlx::query_scalar(
        "UPDATE call_participants p SET state='missed',left_at=now() FROM call_sessions c WHERE p.call_id=c.call_id AND c.state='active' AND p.state IN ('invited','ringing') AND p.invited_at+interval '45 seconds'<=now() RETURNING p.call_id",
    )
    .fetch_all(&mut *tx)
    .await?;
    let failed_connections: Vec<(Uuid, Uuid, Option<String>)> = sqlx::query_as(
        "UPDATE call_participants p SET state='failed',left_at=now() FROM call_sessions c WHERE p.call_id=c.call_id AND c.state='active' AND p.state='connecting' AND p.answered_at IS NOT NULL AND p.answered_at+interval '45 seconds'<=now() RETURNING p.call_id,p.aci,p.livekit_identity",
    )
    .fetch_all(&mut *tx)
    .await?;
    let mut failed_by_call: HashMap<Uuid, Vec<(Uuid, Option<String>)>> = HashMap::new();
    for (call_id, aci, identity) in failed_connections {
        failed_by_call
            .entry(call_id)
            .or_default()
            .push((aci, identity));
    }
    for (call_id, participants) in &failed_by_call {
        for (_, identity) in participants {
            if let Some(identity) = identity.as_deref() {
                enqueue_media_action(&mut tx, *call_id, "remove_participant", identity).await?;
            }
        }
        rotate_epoch(&mut tx, *call_id).await?;
        let host: Uuid = sqlx::query_scalar("SELECT host_aci FROM call_sessions WHERE call_id=$1")
            .bind(call_id)
            .fetch_one(&mut *tx)
            .await?;
        if participants.iter().any(|(aci, _)| *aci == host) {
            transfer_host_or_end(&mut tx, *call_id).await?;
        }
        finish_if_empty(&mut tx, *call_id).await?;
    }

    let rotate: Vec<Uuid> = sqlx::query_scalar(
        "SELECT call_id FROM call_sessions WHERE state='active' AND last_key_rotation_at+interval '30 minutes'<=now() ORDER BY last_key_rotation_at FOR UPDATE SKIP LOCKED LIMIT 100",
    )
    .fetch_all(&mut *tx)
    .await?;
    for call_id in &rotate {
        sqlx::query("UPDATE call_sessions SET call_epoch=call_epoch+1,last_key_rotation_at=now() WHERE call_id=$1 AND state='active'")
            .bind(call_id).execute(&mut *tx).await?;
        coordination_event(&mut tx, *call_id, "roster_changed").await?;
    }
    let deleted = sqlx::query(
        "DELETE FROM call_sessions WHERE state='ended' AND coordination_expires_at<=now()",
    )
    .execute(&mut *tx)
    .await?
    .rows_affected();
    tx.commit().await?;

    let media_actions = process_media_actions(state, 100).await?;

    for (call_id, _) in &expired {
        notify_roster(state, *call_id, "ended").await?;
    }
    for call_id in &rotate {
        notify_roster(state, *call_id, "roster_changed").await?;
    }
    let participant_changes: HashSet<Uuid> = missed_invites
        .iter()
        .copied()
        .chain(failed_by_call.keys().copied())
        .collect();
    for call_id in &participant_changes {
        notify_roster(state, *call_id, "roster_changed").await?;
    }
    Ok(expired.len() as u64
        + rotate.len() as u64
        + missed_invites.len() as u64
        + failed_by_call.values().map(Vec::len).sum::<usize>() as u64
        + deleted
        + media_actions)
}

fn random_opaque_id() -> String {
    let mut bytes = [0_u8; 32];
    rand::rng().fill_bytes(&mut bytes);
    URL_SAFE_NO_PAD.encode(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Serialize)]
    struct TestWebhookClaims<'a> {
        iss: &'a str,
        exp: i64,
        sha256: String,
    }

    #[test]
    fn validates_call_invitees_and_limits() {
        let principal = Uuid::new_v4();
        let invitee = Uuid::new_v4();
        assert!(validate_invitees(&[invitee], principal).is_ok());
        assert!(validate_invitees(&[], principal).is_err());
        assert!(validate_invitees(&[invitee, invitee], principal).is_err());
        assert!(validate_invitees(&[principal], principal).is_err());
    }

    #[test]
    fn opaque_sfu_id_has_no_uuid_shape() {
        let value = random_opaque_id();
        assert_eq!(value.len(), 43);
        assert!(Uuid::parse_str(&value).is_err());
    }

    #[test]
    fn maximum_call_duration_is_eight_hours() {
        assert_eq!(CALL_MAX_SECONDS, 28_800);
    }

    #[test]
    fn media_administration_token_is_short_lived_and_room_scoped() {
        let secret = b"test-only-livekit-secret-at-least-32-bytes";
        let config = CallConfig {
            public_url: "wss://calls.example.test".into(),
            api_key: "test-key".into(),
            signing_key: Arc::new(EncodingKey::from_secret(secret)),
            verification_key: Arc::new(DecodingKey::from_secret(secret)),
            health_url: "https://calls.example.test/".into(),
            health_client: reqwest::Client::new(),
        };
        let token = config
            .admin_token("opaque-room", "remove_participant")
            .unwrap();
        let payload = token.split('.').nth(1).unwrap();
        let claims: serde_json::Value =
            serde_json::from_slice(&URL_SAFE_NO_PAD.decode(payload).unwrap()).unwrap();
        assert_eq!(claims["video"]["roomAdmin"], true);
        assert_eq!(claims["video"]["roomCreate"], false);
        assert_eq!(claims["video"]["roomJoin"], false);
        assert_eq!(claims["video"]["room"], "opaque-room");
        assert!(claims["exp"].as_i64().unwrap() - claims["nbf"].as_i64().unwrap() <= 65);

        let delete_token = config.admin_token("opaque-room", "delete_room").unwrap();
        let delete_payload = delete_token.split('.').nth(1).unwrap();
        let delete_claims: serde_json::Value =
            serde_json::from_slice(&URL_SAFE_NO_PAD.decode(delete_payload).unwrap()).unwrap();
        assert_eq!(delete_claims["video"]["roomCreate"], true);
        assert_eq!(delete_claims["video"]["roomAdmin"], false);
        assert_eq!(delete_claims["video"]["room"], "opaque-room");
    }

    #[test]
    fn webhook_signature_authenticates_the_exact_raw_body() {
        let secret = b"test-only-livekit-secret-at-least-32-bytes";
        let body = br#"{"event":"room_started","id":"EV_test_0001"}"#;
        let config = CallConfig {
            public_url: "wss://calls.example.test".into(),
            api_key: "test-key".into(),
            signing_key: Arc::new(EncodingKey::from_secret(secret)),
            verification_key: Arc::new(DecodingKey::from_secret(secret)),
            health_url: "https://calls.example.test/".into(),
            health_client: reqwest::Client::new(),
        };
        let claims = TestWebhookClaims {
            iss: "test-key",
            exp: Utc::now().timestamp() + 60,
            sha256: base64::engine::general_purpose::STANDARD.encode(Sha256::digest(body)),
        };
        let token = encode(
            &Header::new(Algorithm::HS256),
            &claims,
            &EncodingKey::from_secret(secret),
        )
        .unwrap();
        let mut headers = HeaderMap::new();
        headers.insert(
            header::CONTENT_TYPE,
            "application/webhook+json".parse().unwrap(),
        );
        headers.insert(header::AUTHORIZATION, token.parse().unwrap());
        assert!(config.verify_webhook(&headers, body).is_ok());
        assert!(config
            .verify_webhook(&headers, br#"{"event":"room_finished"}"#)
            .is_err());
    }
}
