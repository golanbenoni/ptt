//! Authenticated UDP tuple binding and ciphertext-only media fan-out.

use anyhow::{Context, Result};
use chrono::Utc;
use hmac::{Hmac, Mac};
use ptt_server_core::{verify_relay_ticket, RelayTicketClaims, MAX_RELAY_LISTENERS};
use sha2::Sha256;
use std::{collections::HashMap, env, net::SocketAddr};
use subtle::ConstantTimeEq;
use tokio::net::UdpSocket;
use tracing::{info, warn};
use uuid::Uuid;

const MAX_DATAGRAM_BYTES: usize = 1_500;
const MEDIA_DATAGRAM_BYTES: usize = 160;
const MEDIA_HEADER_BYTES: usize = 20;
const MEDIA_HMAC_BYTES: usize = 8;
const MEDIA_VERSION: u8 = 1;
const FLAG_HMAC8: u8 = 0x08;
const BIND_MAGIC: &[u8; 4] = b"PTTB";
const ACK_MAGIC: &[u8; 4] = b"PTTA";

#[derive(Debug, Clone)]
struct Binding {
    channel_id: Uuid,
    aci: Uuid,
    device_id: u32,
    sender_demux: u32,
    expires_unix: i64,
    demux_token: [u8; 32],
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .json()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();
    let bind: SocketAddr = env::var("PTT_RELAY_BIND")
        .unwrap_or_else(|_| "0.0.0.0:47000".to_owned())
        .parse()
        .context("parse PTT_RELAY_BIND")?;
    let signing_key =
        env::var("PTT_RELAY_SHARED_SECRET").context("PTT_RELAY_SHARED_SECRET is required")?;
    if signing_key.len() < 32 {
        anyhow::bail!("PTT_RELAY_SHARED_SECRET must contain at least 32 characters");
    }
    let socket = UdpSocket::bind(bind).await?;
    info!(%bind, "relay socket ready");
    let mut buffer = [0_u8; MAX_DATAGRAM_BYTES];
    let mut bindings = HashMap::<SocketAddr, Binding>::new();
    loop {
        let (length, source) = socket.recv_from(&mut buffer).await?;
        let now = Utc::now().timestamp();
        bindings.retain(|_, binding| binding.expires_unix >= now);
        if let Some(ticket) = parse_bind(&buffer[..length]) {
            match verify_relay_ticket(ticket, signing_key.as_bytes(), Utc::now()) {
                Ok(claims) => {
                    if bind_source(&mut bindings, source, claims) {
                        let mut ack = [0_u8; 8];
                        ack[..4].copy_from_slice(ACK_MAGIC);
                        ack[4..].copy_from_slice(&bindings[&source].sender_demux.to_be_bytes());
                        let _ = socket.send_to(&ack, source).await;
                    }
                }
                Err(_) => warn!("dropping invalid relay binding"),
            }
            continue;
        }

        let Some(binding) = bindings.get(&source) else {
            continue;
        };
        if !valid_media(&buffer[..length], binding) {
            continue;
        }
        let targets: Vec<SocketAddr> = bindings
            .iter()
            .filter_map(|(address, candidate)| {
                (*address != source && candidate.channel_id == binding.channel_id)
                    .then_some(*address)
            })
            .collect();
        for target in targets {
            let _ = socket.send_to(&buffer[..length], target).await;
        }
    }
}

fn parse_bind(datagram: &[u8]) -> Option<&str> {
    if datagram.len() <= BIND_MAGIC.len() || &datagram[..4] != BIND_MAGIC {
        return None;
    }
    std::str::from_utf8(&datagram[4..]).ok()
}

fn bind_source(
    bindings: &mut HashMap<SocketAddr, Binding>,
    source: SocketAddr,
    claims: RelayTicketClaims,
) -> bool {
    bindings.remove(&source);
    bindings.retain(|_, binding| {
        binding.channel_id != claims.channel_id
            || binding.aci != claims.aci
            || binding.device_id != claims.device_id
    });
    let listeners = bindings
        .values()
        .filter(|binding| binding.channel_id == claims.channel_id)
        .count();
    if listeners >= MAX_RELAY_LISTENERS {
        return false;
    }
    bindings.insert(
        source,
        Binding {
            channel_id: claims.channel_id,
            aci: claims.aci,
            device_id: claims.device_id,
            sender_demux: claims.sender_demux,
            expires_unix: claims.expires_unix,
            demux_token: claims.demux_token,
        },
    );
    true
}

fn valid_media(datagram: &[u8], binding: &Binding) -> bool {
    if datagram.len() != MEDIA_DATAGRAM_BYTES
        || datagram.len() < MEDIA_HEADER_BYTES + MEDIA_HMAC_BYTES
        || datagram[0] != MEDIA_VERSION
        || datagram[1] & FLAG_HMAC8 == 0
    {
        return false;
    }
    let sender_demux = u32::from_be_bytes(datagram[2..6].try_into().expect("fixed slice"));
    if sender_demux != binding.sender_demux {
        return false;
    }
    let authenticated_bytes = datagram.len() - MEDIA_HMAC_BYTES;
    let mut mac = match Hmac::<Sha256>::new_from_slice(&binding.demux_token) {
        Ok(value) => value,
        Err(_) => return false,
    };
    mac.update(&datagram[..authenticated_bytes]);
    mac.finalize().into_bytes()[..MEDIA_HMAC_BYTES]
        .ct_eq(&datagram[authenticated_bytes..])
        .unwrap_u8()
        == 1
}

#[cfg(test)]
mod tests {
    use super::*;

    fn binding() -> Binding {
        Binding {
            channel_id: Uuid::new_v4(),
            aci: Uuid::new_v4(),
            device_id: 1,
            sender_demux: 42,
            expires_unix: Utc::now().timestamp() + 60,
            demux_token: [7; 32],
        }
    }

    fn signed_media(binding: &Binding) -> [u8; MEDIA_DATAGRAM_BYTES] {
        let mut packet = [0_u8; MEDIA_DATAGRAM_BYTES];
        packet[0] = MEDIA_VERSION;
        packet[1] = FLAG_HMAC8;
        packet[2..6].copy_from_slice(&binding.sender_demux.to_be_bytes());
        let authenticated = MEDIA_DATAGRAM_BYTES - MEDIA_HMAC_BYTES;
        let mut mac = Hmac::<Sha256>::new_from_slice(&binding.demux_token).unwrap();
        mac.update(&packet[..authenticated]);
        packet[authenticated..].copy_from_slice(&mac.finalize().into_bytes()[..MEDIA_HMAC_BYTES]);
        packet
    }

    #[test]
    fn media_requires_bound_demux_and_valid_hmac() {
        let binding = binding();
        let mut packet = signed_media(&binding);
        assert!(valid_media(&packet, &binding));
        packet[40] ^= 1;
        assert!(!valid_media(&packet, &binding));
        let mut packet = signed_media(&binding);
        packet[2..6].copy_from_slice(&43_u32.to_be_bytes());
        assert!(!valid_media(&packet, &binding));
    }

    #[test]
    fn rebinding_replaces_the_old_source_tuple() {
        let claims = RelayTicketClaims {
            channel_id: Uuid::new_v4(),
            aci: Uuid::new_v4(),
            device_id: 2,
            sender_demux: 9,
            expires_unix: Utc::now().timestamp() + 60,
            demux_token: [3; 32],
        };
        let old: SocketAddr = "127.0.0.1:10001".parse().unwrap();
        let new: SocketAddr = "127.0.0.1:10002".parse().unwrap();
        let mut bindings = HashMap::new();
        assert!(bind_source(&mut bindings, old, claims.clone()));
        assert!(bind_source(&mut bindings, new, claims));
        assert!(!bindings.contains_key(&old));
        assert!(bindings.contains_key(&new));
    }
}
