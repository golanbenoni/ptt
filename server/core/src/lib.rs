//! Security-sensitive domain rules shared by the PTT control and relay services.

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use chrono::{DateTime, Duration, Utc};
use hmac::{Hmac, Mac};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use subtle::ConstantTimeEq;
use thiserror::Error;
use uuid::Uuid;

pub const PROTOCOL_MAJOR: u32 = 1;
pub const PROTOCOL_MINOR: u32 = 1;
pub const MINIMUM_CLIENT_MAJOR: u32 = 1;
pub const MINIMUM_CLIENT_MINOR: u32 = 0;
pub const PROTOCOL_CAPABILITIES: &[&str] = &[
    "chat-attachments-v1",
    "chat-encrypted-thumbnails-v1",
    "chat-resumable-transfers-v1",
    "conversation-directory-v1",
    "channel-workspace-v1",
    "operations-runs-v1",
    "scoped-integrations-v1",
    "media-tls-v1",
    "push-wake-v1",
    "push-channel-scope-v1",
];
pub const MAX_ACTIVE_DEVICES: usize = 2;
pub const MAX_CHANNEL_MEMBERS: usize = 64;
pub const MAX_RELAY_LISTENERS: usize = 256;
pub const MAX_PREKEY_BATCH_DEVICES: usize = 128;
pub const MAGIC_LINK_TTL_MINUTES: i64 = 10;
pub const MAX_TALK_TIME_MS: u32 = 30_000;
pub const RELAY_TICKET_TTL_SECONDS: i64 = 300;
const RELAY_TICKET_VERSION: u8 = 1;
const RELAY_TICKET_PAYLOAD_BYTES: usize = 81;
const RELAY_TICKET_TAG_BYTES: usize = 32;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Aci(pub Uuid);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct MailboxId(pub Uuid);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct DeviceId(u32);

impl DeviceId {
    pub fn new(value: u32) -> Result<Self, DomainError> {
        if (1..=MAX_ACTIVE_DEVICES as u32).contains(&value) {
            Ok(Self(value))
        } else {
            Err(DomainError::InvalidDeviceId)
        }
    }

    pub fn get(self) -> u32 {
        self.0
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DeviceStatus {
    Pending,
    Active,
    Revoked,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DeviceAddress {
    pub aci: Aci,
    pub device_id: DeviceId,
    pub mailbox_id: MailboxId,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RelayTicketClaims {
    pub channel_id: Uuid,
    pub aci: Uuid,
    pub device_id: u32,
    pub sender_demux: u32,
    pub expires_unix: i64,
    pub demux_token: [u8; 32],
}

pub fn issue_relay_ticket(
    signing_key: &[u8],
    channel_id: Uuid,
    aci: Uuid,
    device_id: u32,
    sender_demux: u32,
    now: DateTime<Utc>,
) -> Result<(String, RelayTicketClaims), DomainError> {
    DeviceId::new(device_id)?;
    if sender_demux == 0 {
        return Err(DomainError::InvalidSenderDemux);
    }
    if signing_key.len() < 32 {
        return Err(DomainError::InvalidSigningKey);
    }
    let mut demux_token = [0_u8; 32];
    rand::rng().fill_bytes(&mut demux_token);
    let claims = RelayTicketClaims {
        channel_id,
        aci,
        device_id,
        sender_demux,
        expires_unix: (now + Duration::seconds(RELAY_TICKET_TTL_SECONDS)).timestamp(),
        demux_token,
    };
    let payload = encode_relay_claims(&claims);
    let mut mac =
        Hmac::<Sha256>::new_from_slice(signing_key).map_err(|_| DomainError::InvalidSigningKey)?;
    mac.update(&payload);
    let tag = mac.finalize().into_bytes();
    let mut ticket = Vec::with_capacity(RELAY_TICKET_PAYLOAD_BYTES + RELAY_TICKET_TAG_BYTES);
    ticket.extend_from_slice(&payload);
    ticket.extend_from_slice(&tag);
    Ok((URL_SAFE_NO_PAD.encode(ticket), claims))
}

pub fn verify_relay_ticket(
    ticket: &str,
    signing_key: &[u8],
    now: DateTime<Utc>,
) -> Result<RelayTicketClaims, DomainError> {
    if signing_key.len() < 32 {
        return Err(DomainError::InvalidSigningKey);
    }
    let decoded = URL_SAFE_NO_PAD
        .decode(ticket.as_bytes())
        .map_err(|_| DomainError::InvalidRelayTicket)?;
    if decoded.len() != RELAY_TICKET_PAYLOAD_BYTES + RELAY_TICKET_TAG_BYTES {
        return Err(DomainError::InvalidRelayTicket);
    }
    let (payload, tag) = decoded.split_at(RELAY_TICKET_PAYLOAD_BYTES);
    let mut mac =
        Hmac::<Sha256>::new_from_slice(signing_key).map_err(|_| DomainError::InvalidSigningKey)?;
    mac.update(payload);
    mac.verify_slice(tag)
        .map_err(|_| DomainError::InvalidRelayTicket)?;
    let claims = decode_relay_claims(payload)?;
    if claims.expires_unix < now.timestamp() {
        return Err(DomainError::SecretExpired);
    }
    Ok(claims)
}

fn encode_relay_claims(claims: &RelayTicketClaims) -> [u8; RELAY_TICKET_PAYLOAD_BYTES] {
    let mut output = [0_u8; RELAY_TICKET_PAYLOAD_BYTES];
    output[0] = RELAY_TICKET_VERSION;
    output[1..17].copy_from_slice(claims.channel_id.as_bytes());
    output[17..33].copy_from_slice(claims.aci.as_bytes());
    output[33..37].copy_from_slice(&claims.device_id.to_be_bytes());
    output[37..41].copy_from_slice(&claims.sender_demux.to_be_bytes());
    output[41..49].copy_from_slice(&claims.expires_unix.to_be_bytes());
    output[49..81].copy_from_slice(&claims.demux_token);
    output
}

fn decode_relay_claims(payload: &[u8]) -> Result<RelayTicketClaims, DomainError> {
    if payload.len() != RELAY_TICKET_PAYLOAD_BYTES || payload[0] != RELAY_TICKET_VERSION {
        return Err(DomainError::InvalidRelayTicket);
    }
    let channel_id =
        Uuid::from_slice(&payload[1..17]).map_err(|_| DomainError::InvalidRelayTicket)?;
    let aci = Uuid::from_slice(&payload[17..33]).map_err(|_| DomainError::InvalidRelayTicket)?;
    let device_id = u32::from_be_bytes(payload[33..37].try_into().expect("fixed slice"));
    DeviceId::new(device_id)?;
    let sender_demux = u32::from_be_bytes(payload[37..41].try_into().expect("fixed slice"));
    if sender_demux == 0 {
        return Err(DomainError::InvalidSenderDemux);
    }
    let expires_unix = i64::from_be_bytes(payload[41..49].try_into().expect("fixed slice"));
    let demux_token = payload[49..81].try_into().expect("fixed slice");
    Ok(RelayTicketClaims {
        channel_id,
        aci,
        device_id,
        sender_demux,
        expires_unix,
        demux_token,
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MagicLinkPurpose {
    Enroll,
    LinkDevice,
    Recover,
}

impl MagicLinkPurpose {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Enroll => "enroll",
            Self::LinkDevice => "link_device",
            Self::Recover => "recover",
        }
    }
}

#[derive(Debug, Clone)]
pub struct IssuedSecret {
    pub plaintext: String,
    pub sha256: [u8; 32],
}

impl IssuedSecret {
    pub fn issue() -> Self {
        let mut bytes = [0_u8; 32];
        rand::rng().fill_bytes(&mut bytes);
        let plaintext = URL_SAFE_NO_PAD.encode(bytes);
        let sha256 = hash_secret(&plaintext);
        Self { plaintext, sha256 }
    }
}

#[derive(Debug, Clone)]
pub struct MagicLinkRecord {
    pub token_sha256: [u8; 32],
    pub purpose: MagicLinkPurpose,
    pub expires_at: DateTime<Utc>,
    pub consumed_at: Option<DateTime<Utc>>,
}

impl MagicLinkRecord {
    pub fn new(secret: &IssuedSecret, purpose: MagicLinkPurpose, now: DateTime<Utc>) -> Self {
        Self {
            token_sha256: secret.sha256,
            purpose,
            expires_at: now + Duration::minutes(MAGIC_LINK_TTL_MINUTES),
            consumed_at: None,
        }
    }

    pub fn consume(&mut self, plaintext: &str, now: DateTime<Utc>) -> Result<(), DomainError> {
        if self.consumed_at.is_some() {
            return Err(DomainError::SecretConsumed);
        }
        if now > self.expires_at {
            return Err(DomainError::SecretExpired);
        }
        let actual = hash_secret(plaintext);
        if self.token_sha256.ct_eq(&actual).unwrap_u8() != 1 {
            return Err(DomainError::InvalidSecret);
        }
        self.consumed_at = Some(now);
        Ok(())
    }
}

pub fn hash_secret(plaintext: &str) -> [u8; 32] {
    Sha256::digest(plaintext.as_bytes()).into()
}

pub fn secret_matches(expected_sha256: &[u8; 32], plaintext: &str) -> bool {
    expected_sha256.ct_eq(&hash_secret(plaintext)).unwrap_u8() == 1
}

pub fn next_device_id(active_ids: &[u32]) -> Result<DeviceId, DomainError> {
    for candidate in 1..=MAX_ACTIVE_DEVICES as u32 {
        if !active_ids.contains(&candidate) {
            return DeviceId::new(candidate);
        }
    }
    Err(DomainError::DeviceLimit)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FloorPriority {
    Normal = 0,
    Barge = 1,
    Dispatch = 2,
    Sos = 3,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FloorRequest {
    pub channel_id: Uuid,
    pub request_token: [u8; 16],
    pub sender_demux: u32,
    pub membership_epoch: u32,
    pub requested_tot_ms: u32,
    pub priority: FloorPriority,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FloorGrant {
    pub channel_id: Uuid,
    pub request_token: [u8; 16],
    pub sender_demux: u32,
    pub granted_tot_ms: u32,
    pub priority: FloorPriority,
}

#[derive(Default)]
pub struct FloorCoordinator {
    active: HashMap<Uuid, FloorGrant>,
}

impl FloorCoordinator {
    pub fn request(
        &mut self,
        request: FloorRequest,
        current_membership_epoch: u32,
    ) -> Result<FloorGrant, DomainError> {
        if request.membership_epoch != current_membership_epoch {
            return Err(DomainError::StaleMembershipEpoch);
        }
        if request.sender_demux == 0 {
            return Err(DomainError::InvalidSenderDemux);
        }

        if let Some(existing) = self.active.get(&request.channel_id) {
            if existing.request_token == request.request_token {
                return Ok(existing.clone());
            }
            if request.priority <= existing.priority {
                return Err(DomainError::FloorBusy);
            }
        }

        let grant = FloorGrant {
            channel_id: request.channel_id,
            request_token: request.request_token,
            sender_demux: request.sender_demux,
            granted_tot_ms: request.requested_tot_ms.clamp(1_000, MAX_TALK_TIME_MS),
            priority: request.priority,
        };
        self.active.insert(request.channel_id, grant.clone());
        Ok(grant)
    }

    pub fn release(
        &mut self,
        channel_id: Uuid,
        token: &[u8; 16],
    ) -> Result<FloorGrant, DomainError> {
        let current = self
            .active
            .get(&channel_id)
            .ok_or(DomainError::FloorNotHeld)?;
        if current.request_token.ct_eq(token).unwrap_u8() != 1 {
            return Err(DomainError::InvalidSecret);
        }
        self.active
            .remove(&channel_id)
            .ok_or(DomainError::FloorNotHeld)
    }
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum DomainError {
    #[error("device id must be within the active-device limit")]
    InvalidDeviceId,
    #[error("account already has the maximum active devices")]
    DeviceLimit,
    #[error("invalid secret")]
    InvalidSecret,
    #[error("secret has expired")]
    SecretExpired,
    #[error("secret was already consumed")]
    SecretConsumed,
    #[error("membership epoch is stale")]
    StaleMembershipEpoch,
    #[error("sender demux must be nonzero")]
    InvalidSenderDemux,
    #[error("floor is busy")]
    FloorBusy,
    #[error("floor is not held")]
    FloorNotHeld,
    #[error("relay signing key must contain at least 32 bytes")]
    InvalidSigningKey,
    #[error("relay ticket is malformed or unauthenticated")]
    InvalidRelayTicket,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn magic_link_is_single_use_and_constant_hash_length() {
        let now = Utc::now();
        let secret = IssuedSecret::issue();
        let mut record = MagicLinkRecord::new(&secret, MagicLinkPurpose::Enroll, now);
        assert_eq!(secret.sha256.len(), 32);
        assert_eq!(record.consume(&secret.plaintext, now), Ok(()));
        assert_eq!(
            record.consume(&secret.plaintext, now),
            Err(DomainError::SecretConsumed)
        );
    }

    #[test]
    fn magic_link_rejects_wrong_and_expired_secrets() {
        let now = Utc::now();
        let secret = IssuedSecret::issue();
        let mut wrong = MagicLinkRecord::new(&secret, MagicLinkPurpose::Enroll, now);
        assert_eq!(
            wrong.consume("not-the-token", now),
            Err(DomainError::InvalidSecret)
        );

        let mut expired = MagicLinkRecord::new(&secret, MagicLinkPurpose::Enroll, now);
        assert_eq!(
            expired.consume(&secret.plaintext, now + Duration::minutes(11)),
            Err(DomainError::SecretExpired)
        );
    }

    #[test]
    fn secret_comparison_accepts_only_the_issued_value() {
        let expected = hash_secret("correct horse battery staple");
        assert!(secret_matches(&expected, "correct horse battery staple"));
        assert!(!secret_matches(&expected, "correct horse battery staplf"));
    }

    #[test]
    fn relay_ticket_round_trip_rejects_tampering_and_expiry() {
        let now = Utc::now();
        let key = b"test-only-relay-signing-key-32-bytes";
        let (ticket, expected) =
            issue_relay_ticket(key, Uuid::new_v4(), Uuid::new_v4(), 2, 42, now).unwrap();
        assert_eq!(verify_relay_ticket(&ticket, key, now).unwrap(), expected);
        let mut tampered = ticket.into_bytes();
        tampered[12] = if tampered[12] == b'A' { b'B' } else { b'A' };
        assert_eq!(
            verify_relay_ticket(std::str::from_utf8(&tampered).unwrap(), key, now),
            Err(DomainError::InvalidRelayTicket)
        );
        let (expired, _) = issue_relay_ticket(
            key,
            Uuid::new_v4(),
            Uuid::new_v4(),
            1,
            7,
            now - Duration::seconds(RELAY_TICKET_TTL_SECONDS + 1),
        )
        .unwrap();
        assert_eq!(
            verify_relay_ticket(&expired, key, now),
            Err(DomainError::SecretExpired)
        );
    }

    #[test]
    fn only_two_active_device_ids_are_issued() {
        assert_eq!(next_device_id(&[]).unwrap().get(), 1);
        assert_eq!(next_device_id(&[1]).unwrap().get(), 2);
        assert_eq!(next_device_id(&[1, 2]), Err(DomainError::DeviceLimit));
    }

    #[test]
    fn higher_priority_preempts_and_tot_is_capped() {
        let channel_id = Uuid::new_v4();
        let mut floors = FloorCoordinator::default();
        let normal = FloorRequest {
            channel_id,
            request_token: [1; 16],
            sender_demux: 10,
            membership_epoch: 4,
            requested_tot_ms: 60_000,
            priority: FloorPriority::Normal,
        };
        let grant = floors.request(normal, 4).unwrap();
        assert_eq!(grant.granted_tot_ms, MAX_TALK_TIME_MS);

        let busy = FloorRequest {
            channel_id,
            request_token: [2; 16],
            sender_demux: 11,
            membership_epoch: 4,
            requested_tot_ms: 5_000,
            priority: FloorPriority::Normal,
        };
        assert_eq!(floors.request(busy, 4), Err(DomainError::FloorBusy));

        let sos = FloorRequest {
            channel_id,
            request_token: [3; 16],
            sender_demux: 12,
            membership_epoch: 4,
            requested_tot_ms: 10_000,
            priority: FloorPriority::Sos,
        };
        assert_eq!(floors.request(sos, 4).unwrap().sender_demux, 12);
    }
}
