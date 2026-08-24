use chrono::{DateTime, Utc};
use hmac::{Hmac, Mac};
use reqwest::{header, Client, Method, Url};
use sha2::{Digest, Sha256};
use std::time::Duration;
use thiserror::Error;

const REGION: &str = "us-east-1";
const SERVICE: &str = "s3";
#[derive(Clone)]
pub struct ObjectStore {
    client: Client,
    endpoint: Url,
    bucket: String,
    access_key: String,
    secret_key: String,
}

#[derive(Debug, Error)]
pub enum ObjectStoreError {
    #[error("invalid object-store configuration")]
    InvalidConfiguration,
    #[error("object-store request failed")]
    Request,
    #[error("object-store returned HTTP {0}")]
    Response(u16),
    #[error("object-store response exceeded its declared limit")]
    TooLarge,
}

impl ObjectStore {
    pub fn new(
        endpoint: &str,
        bucket: String,
        access_key: String,
        secret_key: String,
    ) -> Result<Self, ObjectStoreError> {
        let mut endpoint =
            Url::parse(endpoint).map_err(|_| ObjectStoreError::InvalidConfiguration)?;
        if endpoint.scheme() != "http" && endpoint.scheme() != "https" {
            return Err(ObjectStoreError::InvalidConfiguration);
        }
        if endpoint.query().is_some()
            || endpoint.fragment().is_some()
            || endpoint.cannot_be_a_base()
            || access_key.is_empty()
            || secret_key.len() < 8
            || !valid_bucket(&bucket)
        {
            return Err(ObjectStoreError::InvalidConfiguration);
        }
        let endpoint_path = endpoint.path().trim_end_matches('/').to_owned();
        endpoint.set_path(&endpoint_path);
        let client = Client::builder()
            .connect_timeout(Duration::from_secs(5))
            .timeout(Duration::from_secs(30))
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(|_| ObjectStoreError::InvalidConfiguration)?;
        Ok(Self {
            client,
            endpoint,
            bucket,
            access_key,
            secret_key,
        })
    }

    pub async fn ready(&self) -> Result<(), ObjectStoreError> {
        self.execute(Method::HEAD, None, Vec::new(), 0).await?;
        Ok(())
    }

    pub async fn put(&self, key: &str, ciphertext: Vec<u8>) -> Result<(), ObjectStoreError> {
        validate_key(key)?;
        self.execute(Method::PUT, Some(key), ciphertext, 0).await?;
        Ok(())
    }

    pub async fn get(&self, key: &str, maximum: usize) -> Result<Vec<u8>, ObjectStoreError> {
        validate_key(key)?;
        let response = self
            .execute(Method::GET, Some(key), Vec::new(), maximum)
            .await?;
        if response.len() > maximum {
            return Err(ObjectStoreError::TooLarge);
        }
        Ok(response)
    }

    pub async fn delete(&self, key: &str) -> Result<(), ObjectStoreError> {
        validate_key(key)?;
        self.execute(Method::DELETE, Some(key), Vec::new(), 0)
            .await?;
        Ok(())
    }

    async fn execute(
        &self,
        method: Method,
        key: Option<&str>,
        body: Vec<u8>,
        maximum_response: usize,
    ) -> Result<Vec<u8>, ObjectStoreError> {
        let url = self.url(key)?;
        let deleting = method == Method::DELETE;
        let now = Utc::now();
        let payload_hash = hex::encode(Sha256::digest(&body));
        let authorization = authorization(
            method.as_str(),
            url.path(),
            url.host_str()
                .ok_or(ObjectStoreError::InvalidConfiguration)?,
            url.port(),
            &payload_hash,
            now,
            &self.access_key,
            &self.secret_key,
        );
        let amz_date = now.format("%Y%m%dT%H%M%SZ").to_string();
        let mut request = self
            .client
            .request(method, url)
            .header(header::AUTHORIZATION, authorization)
            .header("x-amz-content-sha256", payload_hash)
            .header("x-amz-date", amz_date);
        if !body.is_empty() {
            request = request.body(body);
        }
        let response = request
            .send()
            .await
            .map_err(|_| ObjectStoreError::Request)?;
        if !response.status().is_success()
            && !(deleting && response.status() == reqwest::StatusCode::NOT_FOUND)
        {
            return Err(ObjectStoreError::Response(response.status().as_u16()));
        }
        if maximum_response == 0 {
            return Ok(Vec::new());
        }
        if response
            .content_length()
            .is_some_and(|length| length > maximum_response as u64)
        {
            return Err(ObjectStoreError::TooLarge);
        }
        let bytes = response
            .bytes()
            .await
            .map_err(|_| ObjectStoreError::Request)?;
        if bytes.len() > maximum_response {
            return Err(ObjectStoreError::TooLarge);
        }
        Ok(bytes.to_vec())
    }

    fn url(&self, key: Option<&str>) -> Result<Url, ObjectStoreError> {
        let mut url = self.endpoint.clone();
        let path = match key {
            Some(key) => format!("/{}/{key}", self.bucket),
            None => format!("/{}", self.bucket),
        };
        url.set_path(&path);
        Ok(url)
    }
}

fn valid_bucket(bucket: &str) -> bool {
    (3..=63).contains(&bucket.len())
        && bucket.bytes().all(|byte| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-' || byte == b'.'
        })
        && bucket
            .as_bytes()
            .first()
            .is_some_and(u8::is_ascii_alphanumeric)
        && bucket
            .as_bytes()
            .last()
            .is_some_and(u8::is_ascii_alphanumeric)
}

fn validate_key(key: &str) -> Result<(), ObjectStoreError> {
    if key.is_empty()
        || key.len() > 512
        || key.starts_with('/')
        || key.contains("..")
        || !key
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'/' | b'-' | b'_' | b'.'))
    {
        return Err(ObjectStoreError::InvalidConfiguration);
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn authorization(
    method: &str,
    canonical_uri: &str,
    host: &str,
    port: Option<u16>,
    payload_hash: &str,
    now: DateTime<Utc>,
    access_key: &str,
    secret_key: &str,
) -> String {
    let authority = match port {
        Some(port) => format!("{host}:{port}"),
        _ => host.to_owned(),
    };
    let amz_date = now.format("%Y%m%dT%H%M%SZ").to_string();
    let short_date = now.format("%Y%m%d").to_string();
    let canonical_headers =
        format!("host:{authority}\nx-amz-content-sha256:{payload_hash}\nx-amz-date:{amz_date}\n");
    let signed_headers = "host;x-amz-content-sha256;x-amz-date";
    let canonical_request = format!(
        "{method}\n{canonical_uri}\n\n{canonical_headers}\n{signed_headers}\n{payload_hash}"
    );
    let scope = format!("{short_date}/{REGION}/{SERVICE}/aws4_request");
    let string_to_sign = format!(
        "AWS4-HMAC-SHA256\n{amz_date}\n{scope}\n{}",
        hex::encode(Sha256::digest(canonical_request.as_bytes()))
    );
    let date_key = hmac(
        format!("AWS4{secret_key}").as_bytes(),
        short_date.as_bytes(),
    );
    let region_key = hmac(&date_key, REGION.as_bytes());
    let service_key = hmac(&region_key, SERVICE.as_bytes());
    let signing_key = hmac(&service_key, b"aws4_request");
    let signature = hex::encode(hmac(&signing_key, string_to_sign.as_bytes()));
    format!(
        "AWS4-HMAC-SHA256 Credential={access_key}/{scope}, SignedHeaders={signed_headers}, Signature={signature}"
    )
}

fn hmac(key: &[u8], value: &[u8]) -> Vec<u8> {
    let mut mac = Hmac::<Sha256>::new_from_slice(key).expect("HMAC accepts any key length");
    mac.update(value);
    mac.finalize().into_bytes().to_vec()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_bucket_and_object_key_boundaries() {
        assert!(valid_bucket("ptt-history"));
        assert!(!valid_bucket("PTT-History"));
        assert!(validate_key("history/1234.bin").is_ok());
        assert!(validate_key("../secret").is_err());
        assert!(validate_key("history/key with spaces").is_err());
    }

    #[test]
    fn signature_is_deterministic_and_scoped_without_exposing_secret() {
        let now = DateTime::parse_from_rfc3339("2026-08-23T20:15:30Z")
            .unwrap()
            .with_timezone(&Utc);
        let signature = authorization(
            "HEAD",
            "/ptt-history",
            "127.0.0.1",
            Some(28082),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            now,
            "ptt",
            "not-a-real-secret",
        );
        assert_eq!(
            signature,
            "AWS4-HMAC-SHA256 Credential=ptt/20260823/us-east-1/s3/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=23cdcf0470f3035398375fb98f562e846570d8738e84960283b66498e15a6315"
        );
        assert!(!signature.contains("not-a-real-secret"));
    }
}
