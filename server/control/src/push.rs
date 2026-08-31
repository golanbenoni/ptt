use anyhow::{Context, Result};
use chrono::Utc;
use jsonwebtoken::{encode, Algorithm, EncodingKey, Header};
use reqwest::{Client, StatusCode, Url};
use serde::{Deserialize, Serialize};
use std::{env, sync::Arc, time::Duration};
use tokio::sync::Mutex;
use uuid::Uuid;

const FCM_SCOPE: &str = "https://www.googleapis.com/auth/firebase.messaging";

#[derive(Clone)]
pub struct PushDispatcher {
    client: Client,
    fcm: Option<Arc<FcmConfig>>,
    apns_production: Option<Arc<ApnsConfig>>,
    apns_sandbox: Option<Arc<ApnsConfig>>,
}

struct FcmConfig {
    project_id: String,
    client_email: String,
    private_key_id: Option<String>,
    token_uri: Url,
    send_endpoint: Url,
    key: EncodingKey,
    token: Mutex<Option<CachedToken>>,
}

struct ApnsConfig {
    key_id: String,
    team_id: String,
    bundle_id: String,
    endpoint: Url,
    key: EncodingKey,
    token: Mutex<Option<CachedToken>>,
}

#[derive(Clone)]
struct CachedToken {
    value: String,
    refresh_at: i64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PushResult {
    Delivered,
    InvalidRegistration,
    Retry,
    NotConfigured,
}

#[derive(Debug, Deserialize)]
struct ServiceAccount {
    project_id: String,
    private_key_id: Option<String>,
    private_key: String,
    client_email: String,
    token_uri: String,
}

#[derive(Debug, Serialize)]
struct OAuthClaims<'a> {
    iss: &'a str,
    scope: &'a str,
    aud: &'a str,
    iat: i64,
    exp: i64,
}

#[derive(Debug, Deserialize)]
struct OAuthResponse {
    access_token: String,
    expires_in: i64,
}

#[derive(Debug, Serialize)]
struct ApnsClaims<'a> {
    iss: &'a str,
    iat: i64,
}

impl PushDispatcher {
    pub fn from_env() -> Result<Self> {
        let client = Client::builder()
            .connect_timeout(Duration::from_secs(5))
            .timeout(Duration::from_secs(15))
            .redirect(reqwest::redirect::Policy::none())
            .http2_adaptive_window(true)
            .build()
            .context("build push HTTP client")?;
        let fcm = match env::var("PTT_FCM_SERVICE_ACCOUNT_JSON") {
            Ok(json) => Some(Arc::new(FcmConfig::new(&json)?)),
            Err(env::VarError::NotPresent) => None,
            Err(error) => return Err(error).context("read PTT_FCM_SERVICE_ACCOUNT_JSON"),
        };
        let apns_production =
            ApnsConfig::from_env("PRODUCTION", "https://api.push.apple.com/")?.map(Arc::new);
        let apns_sandbox =
            ApnsConfig::from_env("SANDBOX", "https://api.sandbox.push.apple.com/")?.map(Arc::new);
        Ok(Self {
            client,
            fcm,
            apns_production,
            apns_sandbox,
        })
    }

    pub fn has_provider(&self, provider: &str) -> bool {
        match provider {
            "fcm" => self.fcm.is_some(),
            "apns" | "apns-ptt" => self.apns_production.is_some(),
            "apns-sandbox" | "apns-ptt-sandbox" => self.apns_sandbox.is_some(),
            _ => false,
        }
    }

    pub async fn send(&self, provider: &str, token: &[u8], message_id: Uuid) -> PushResult {
        match provider {
            "fcm" => match &self.fcm {
                Some(config) => self.send_fcm(config, token, message_id).await,
                None => PushResult::NotConfigured,
            },
            "apns" | "apns-ptt" => match &self.apns_production {
                Some(config) => self.send_apns(config, provider, token, message_id).await,
                None => PushResult::NotConfigured,
            },
            "apns-sandbox" | "apns-ptt-sandbox" => match &self.apns_sandbox {
                Some(config) => self.send_apns(config, provider, token, message_id).await,
                None => PushResult::NotConfigured,
            },
            _ => PushResult::InvalidRegistration,
        }
    }

    async fn send_fcm(
        &self,
        config: &FcmConfig,
        registration: &[u8],
        message_id: Uuid,
    ) -> PushResult {
        let Ok(registration) = std::str::from_utf8(registration) else {
            return PushResult::InvalidRegistration;
        };
        let Some(access_token) = self.fcm_access_token(config).await else {
            return PushResult::Retry;
        };
        let endpoint = match config
            .send_endpoint
            .join(&format!("v1/projects/{}/messages:send", config.project_id))
        {
            Ok(endpoint) => endpoint,
            Err(_) => return PushResult::Retry,
        };
        let payload = serde_json::json!({
            "message": {
                "token": registration,
                "data": {"kind": "mailbox", "messageId": message_id.to_string()},
                "android": {"priority": "high"}
            }
        });
        match self
            .client
            .post(endpoint)
            .bearer_auth(access_token)
            .json(&payload)
            .send()
            .await
        {
            Ok(response) => classify_provider_status(response.status()),
            Err(_) => PushResult::Retry,
        }
    }

    async fn fcm_access_token(&self, config: &FcmConfig) -> Option<String> {
        let now = Utc::now().timestamp();
        let mut cached = config.token.lock().await;
        if let Some(token) = cached.as_ref().filter(|token| token.refresh_at > now) {
            return Some(token.value.clone());
        }
        let mut header = Header::new(Algorithm::RS256);
        header.kid.clone_from(&config.private_key_id);
        let audience = config.token_uri.as_str();
        let claims = OAuthClaims {
            iss: &config.client_email,
            scope: FCM_SCOPE,
            aud: audience,
            iat: now,
            exp: now + 3_600,
        };
        let assertion = encode(&header, &claims, &config.key).ok()?;
        let response = self
            .client
            .post(config.token_uri.clone())
            .form(&[
                ("grant_type", "urn:ietf:params:oauth:grant-type:jwt-bearer"),
                ("assertion", assertion.as_str()),
            ])
            .send()
            .await
            .ok()?;
        if !response.status().is_success() {
            return None;
        }
        let response: OAuthResponse = response.json().await.ok()?;
        if response.access_token.is_empty() || response.expires_in <= 0 {
            return None;
        }
        let refresh_at = now + response.expires_in.saturating_sub(300);
        let value = response.access_token;
        *cached = Some(CachedToken {
            value: value.clone(),
            refresh_at,
        });
        Some(value)
    }

    async fn send_apns(
        &self,
        config: &ApnsConfig,
        provider: &str,
        registration: &[u8],
        message_id: Uuid,
    ) -> PushResult {
        if registration.is_empty() || registration.len() > 256 {
            return PushResult::InvalidRegistration;
        }
        let provider_token = match apns_provider_token(config).await {
            Some(token) => token,
            None => return PushResult::Retry,
        };
        let device_token = hex::encode(registration);
        let endpoint = match config.endpoint.join(&format!("3/device/{device_token}")) {
            Ok(endpoint) => endpoint,
            Err(_) => return PushResult::Retry,
        };
        let is_ptt = provider.starts_with("apns-ptt");
        let topic = if is_ptt {
            format!("{}.voip-ptt", config.bundle_id)
        } else {
            config.bundle_id.clone()
        };
        let payload = if is_ptt {
            serde_json::json!({"kind": "mailbox", "messageId": message_id.to_string()})
        } else {
            serde_json::json!({
                "aps": {"content-available": 1},
                "kind": "mailbox",
                "messageId": message_id.to_string()
            })
        };
        match self
            .client
            .post(endpoint)
            .bearer_auth(provider_token)
            .header("apns-topic", topic)
            .header(
                "apns-push-type",
                if is_ptt { "pushtotalk" } else { "background" },
            )
            .header("apns-priority", if is_ptt { "10" } else { "5" })
            .header("apns-expiration", "0")
            .json(&payload)
            .send()
            .await
        {
            Ok(response) => classify_provider_status(response.status()),
            Err(_) => PushResult::Retry,
        }
    }
}

impl FcmConfig {
    fn new(json: &str) -> Result<Self> {
        let account: ServiceAccount =
            serde_json::from_str(json).context("parse FCM service account")?;
        let token_uri = Url::parse(&account.token_uri).context("parse FCM token URI")?;
        require_https_or_loopback(&token_uri, "FCM token URI")?;
        let send_endpoint = env::var("PTT_FCM_ENDPOINT")
            .unwrap_or_else(|_| "https://fcm.googleapis.com/".to_owned());
        let send_endpoint = Url::parse(&send_endpoint).context("parse FCM endpoint")?;
        require_https_or_loopback(&send_endpoint, "FCM endpoint")?;
        let key = EncodingKey::from_rsa_pem(account.private_key.as_bytes())
            .context("parse FCM private key")?;
        if account.project_id.is_empty() || account.client_email.is_empty() {
            anyhow::bail!("FCM service account is incomplete");
        }
        Ok(Self {
            project_id: account.project_id,
            client_email: account.client_email,
            private_key_id: account.private_key_id,
            token_uri,
            send_endpoint,
            key,
            token: Mutex::new(None),
        })
    }
}

impl ApnsConfig {
    fn from_env(environment: &str, default_endpoint: &str) -> Result<Option<Self>> {
        let key_id_name = format!("PTT_APNS_{environment}_KEY_ID");
        let private_key_name = format!("PTT_APNS_{environment}_PRIVATE_KEY");
        let endpoint_name = format!("PTT_APNS_{environment}_ENDPOINT");
        let key_id = env::var(&key_id_name).ok();
        let team_id = env::var("PTT_APNS_TEAM_ID").ok();
        let bundle_id = env::var("PTT_APNS_BUNDLE_ID").ok();
        let private_key = env::var(&private_key_name).ok();
        if key_id.is_none() && private_key.is_none() {
            return Ok(None);
        }
        let key_id = key_id.with_context(|| format!("{key_id_name} is required"))?;
        let team_id = team_id.context("PTT_APNS_TEAM_ID is required")?;
        let bundle_id = bundle_id.context("PTT_APNS_BUNDLE_ID is required")?;
        let private_key = private_key.with_context(|| format!("{private_key_name} is required"))?;
        if key_id.len() != 10 || team_id.len() != 10 || bundle_id.is_empty() {
            anyhow::bail!("APNs identifiers are invalid");
        }
        let endpoint = env::var(&endpoint_name).unwrap_or_else(|_| default_endpoint.to_owned());
        let endpoint = Url::parse(&endpoint).context("parse APNs endpoint")?;
        require_https_or_loopback(&endpoint, "APNs endpoint")?;
        let key =
            EncodingKey::from_ec_pem(private_key.as_bytes()).context("parse APNs private key")?;
        Ok(Some(Self {
            key_id,
            team_id,
            bundle_id,
            endpoint,
            key,
            token: Mutex::new(None),
        }))
    }
}

async fn apns_provider_token(config: &ApnsConfig) -> Option<String> {
    let now = Utc::now().timestamp();
    let mut cached = config.token.lock().await;
    if let Some(token) = cached.as_ref().filter(|token| token.refresh_at > now) {
        return Some(token.value.clone());
    }
    let mut header = Header::new(Algorithm::ES256);
    header.kid = Some(config.key_id.clone());
    let value = encode(
        &header,
        &ApnsClaims {
            iss: &config.team_id,
            iat: now,
        },
        &config.key,
    )
    .ok()?;
    *cached = Some(CachedToken {
        value: value.clone(),
        refresh_at: now + 50 * 60,
    });
    Some(value)
}

fn classify_provider_status(status: StatusCode) -> PushResult {
    if status.is_success() {
        PushResult::Delivered
    } else if matches!(
        status,
        StatusCode::BAD_REQUEST | StatusCode::NOT_FOUND | StatusCode::GONE
    ) {
        PushResult::InvalidRegistration
    } else {
        PushResult::Retry
    }
}

fn require_https_or_loopback(url: &Url, label: &str) -> Result<()> {
    if url.scheme() == "https"
        || (url.scheme() == "http" && matches!(url.host_str(), Some("127.0.0.1" | "::1")))
    {
        Ok(())
    } else {
        anyhow::bail!("{label} must use HTTPS");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classifies_permanent_and_retryable_provider_responses() {
        assert_eq!(
            classify_provider_status(StatusCode::OK),
            PushResult::Delivered
        );
        assert_eq!(
            classify_provider_status(StatusCode::GONE),
            PushResult::InvalidRegistration
        );
        assert_eq!(
            classify_provider_status(StatusCode::BAD_REQUEST),
            PushResult::InvalidRegistration
        );
        assert_eq!(
            classify_provider_status(StatusCode::TOO_MANY_REQUESTS),
            PushResult::Retry
        );
        assert_eq!(
            classify_provider_status(StatusCode::INTERNAL_SERVER_ERROR),
            PushResult::Retry
        );
    }

    #[test]
    fn refuses_plaintext_provider_endpoints_except_loopback_tests() {
        assert!(require_https_or_loopback(
            &Url::parse("https://oauth2.googleapis.com/token").unwrap(),
            "token"
        )
        .is_ok());
        assert!(require_https_or_loopback(
            &Url::parse("http://oauth2.googleapis.com/token").unwrap(),
            "token"
        )
        .is_err());
        assert!(
            require_https_or_loopback(&Url::parse("http://127.0.0.1:8080/").unwrap(), "test")
                .is_ok()
        );
    }
}
