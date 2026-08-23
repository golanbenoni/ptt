//! RFC 9605 SFrame using the AES_128_GCM_SHA256_128 cipher suite.
//!
//! The application owns key distribution and durable counter storage. This
//! crate consumes a counter before encryption and rejects replayed frames.

use aes_gcm::{
    aead::{Aead, Payload},
    Aes128Gcm, KeyInit, Nonce,
};
use hkdf::Hkdf;
use sha2::Sha256;
use std::collections::HashMap;
use thiserror::Error;

pub const AES_128_GCM_SHA256_128: u16 = 0x0004;
const KEY_BYTES: usize = 16;
const NONCE_BYTES: usize = 12;
const TAG_BYTES: usize = 16;
const REPLAY_WINDOW_BITS: u64 = 128;

pub trait CounterStore {
    /// Persist and return the next unused counter. Persistence must complete
    /// before this method returns so a crash can skip, but never reuse, a CTR.
    fn take_next(&mut self, kid: u64) -> Result<u64, SframeError>;
}

#[derive(Debug, Default)]
pub struct MemoryCounterStore {
    next: HashMap<u64, u64>,
}

impl CounterStore for MemoryCounterStore {
    fn take_next(&mut self, kid: u64) -> Result<u64, SframeError> {
        let next = self.next.entry(kid).or_default();
        if *next == u64::MAX {
            return Err(SframeError::CounterExhausted);
        }
        let result = *next;
        *next += 1;
        Ok(result)
    }
}

pub struct Encryptor<C: CounterStore> {
    kid: u64,
    key: [u8; KEY_BYTES],
    salt: [u8; NONCE_BYTES],
    counters: C,
}

impl<C: CounterStore> Encryptor<C> {
    pub fn new(kid: u64, base_key: &[u8], counters: C) -> Result<Self, SframeError> {
        let (key, salt) = derive_key_salt(kid, base_key)?;
        Ok(Self {
            kid,
            key,
            salt,
            counters,
        })
    }

    pub fn encrypt(&mut self, metadata: &[u8], plaintext: &[u8]) -> Result<Vec<u8>, SframeError> {
        let ctr = self.counters.take_next(self.kid)?;
        self.encrypt_with_consumed_counter(ctr, metadata, plaintext)
    }

    fn encrypt_with_consumed_counter(
        &self,
        ctr: u64,
        metadata: &[u8],
        plaintext: &[u8],
    ) -> Result<Vec<u8>, SframeError> {
        let header = encode_header(self.kid, ctr);
        let aad = join_aad(&header, metadata)?;
        let cipher = Aes128Gcm::new_from_slice(&self.key).map_err(|_| SframeError::InvalidKey)?;
        let ciphertext = cipher
            .encrypt(
                Nonce::from_slice(&nonce(&self.salt, ctr)),
                Payload {
                    msg: plaintext,
                    aad: &aad,
                },
            )
            .map_err(|_| SframeError::AuthenticationFailed)?;
        let mut output = Vec::with_capacity(header.len() + ciphertext.len());
        output.extend_from_slice(&header);
        output.extend_from_slice(&ciphertext);
        Ok(output)
    }
}

pub struct Decryptor {
    keys: HashMap<u64, ([u8; KEY_BYTES], [u8; NONCE_BYTES])>,
    replay: HashMap<u64, ReplayWindow>,
}

impl Decryptor {
    pub fn new() -> Self {
        Self {
            keys: HashMap::new(),
            replay: HashMap::new(),
        }
    }

    pub fn add_key(&mut self, kid: u64, base_key: &[u8]) -> Result<(), SframeError> {
        self.keys.insert(kid, derive_key_salt(kid, base_key)?);
        self.replay.remove(&kid);
        Ok(())
    }

    pub fn remove_key(&mut self, kid: u64) {
        self.keys.remove(&kid);
        self.replay.remove(&kid);
    }

    pub fn decrypt(&mut self, metadata: &[u8], frame: &[u8]) -> Result<Vec<u8>, SframeError> {
        let parsed = parse_header(frame)?;
        let (key, salt) = self.keys.get(&parsed.kid).ok_or(SframeError::UnknownKey)?;
        let window = self.replay.entry(parsed.kid).or_default();
        if !window.acceptable(parsed.ctr) {
            return Err(SframeError::Replay);
        }
        if frame.len() < parsed.header_len + TAG_BYTES {
            return Err(SframeError::MalformedHeader);
        }
        let aad = join_aad(&frame[..parsed.header_len], metadata)?;
        let cipher = Aes128Gcm::new_from_slice(key).map_err(|_| SframeError::InvalidKey)?;
        let plaintext = cipher
            .decrypt(
                Nonce::from_slice(&nonce(salt, parsed.ctr)),
                Payload {
                    msg: &frame[parsed.header_len..],
                    aad: &aad,
                },
            )
            .map_err(|_| SframeError::AuthenticationFailed)?;
        window.mark(parsed.ctr);
        Ok(plaintext)
    }
}

impl Default for Decryptor {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Debug, Clone, Copy, Default)]
struct ReplayWindow {
    highest: u64,
    bitmap: u128,
    initialized: bool,
}

impl ReplayWindow {
    fn acceptable(&self, ctr: u64) -> bool {
        if !self.initialized || ctr > self.highest {
            return true;
        }
        let distance = self.highest - ctr;
        distance < REPLAY_WINDOW_BITS && self.bitmap & (1_u128 << distance) == 0
    }

    fn mark(&mut self, ctr: u64) {
        if !self.initialized {
            self.highest = ctr;
            self.bitmap = 1;
            self.initialized = true;
        } else if ctr > self.highest {
            let shift = ctr - self.highest;
            self.bitmap = if shift >= REPLAY_WINDOW_BITS {
                1
            } else {
                (self.bitmap << shift) | 1
            };
            self.highest = ctr;
        } else {
            self.bitmap |= 1_u128 << (self.highest - ctr);
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct ParsedHeader {
    kid: u64,
    ctr: u64,
    header_len: usize,
}

fn derive_key_salt(
    kid: u64,
    base_key: &[u8],
) -> Result<([u8; KEY_BYTES], [u8; NONCE_BYTES]), SframeError> {
    if base_key.is_empty() {
        return Err(SframeError::InvalidKey);
    }
    let hkdf = Hkdf::<Sha256>::new(Some(&[]), base_key);
    let mut key_label = b"SFrame 1.0 Secret key ".to_vec();
    key_label.extend_from_slice(&kid.to_be_bytes());
    key_label.extend_from_slice(&AES_128_GCM_SHA256_128.to_be_bytes());
    let mut salt_label = b"SFrame 1.0 Secret salt ".to_vec();
    salt_label.extend_from_slice(&kid.to_be_bytes());
    salt_label.extend_from_slice(&AES_128_GCM_SHA256_128.to_be_bytes());
    let mut key = [0_u8; KEY_BYTES];
    let mut salt = [0_u8; NONCE_BYTES];
    hkdf.expand(&key_label, &mut key)
        .map_err(|_| SframeError::InvalidKey)?;
    hkdf.expand(&salt_label, &mut salt)
        .map_err(|_| SframeError::InvalidKey)?;
    Ok((key, salt))
}

fn nonce(salt: &[u8; NONCE_BYTES], ctr: u64) -> [u8; NONCE_BYTES] {
    let mut result = *salt;
    for (target, value) in result[NONCE_BYTES - 8..].iter_mut().zip(ctr.to_be_bytes()) {
        *target ^= value;
    }
    result
}

fn join_aad(header: &[u8], metadata: &[u8]) -> Result<Vec<u8>, SframeError> {
    let length = header
        .len()
        .checked_add(metadata.len())
        .ok_or(SframeError::InputTooLarge)?;
    let mut aad = Vec::with_capacity(length);
    aad.extend_from_slice(header);
    aad.extend_from_slice(metadata);
    Ok(aad)
}

pub fn encode_header(kid: u64, ctr: u64) -> Vec<u8> {
    let kid_bytes = compact_bytes(kid);
    let ctr_bytes = compact_bytes(ctr);
    let kid_extended = kid >= 8;
    let ctr_extended = ctr >= 8;
    let mut config = 0_u8;
    if kid_extended {
        config |= 0x80 | (((kid_bytes.len() - 1) as u8) << 4);
    } else {
        config |= (kid as u8) << 4;
    }
    if ctr_extended {
        config |= 0x08 | ((ctr_bytes.len() - 1) as u8);
    } else {
        config |= ctr as u8;
    }
    let mut header = Vec::with_capacity(1 + kid_bytes.len() + ctr_bytes.len());
    header.push(config);
    if kid_extended {
        header.extend_from_slice(&kid_bytes);
    }
    if ctr_extended {
        header.extend_from_slice(&ctr_bytes);
    }
    header
}

fn parse_header(frame: &[u8]) -> Result<ParsedHeader, SframeError> {
    let config = *frame.first().ok_or(SframeError::MalformedHeader)?;
    let kid_extended = config & 0x80 != 0;
    let ctr_extended = config & 0x08 != 0;
    let kid_length = if kid_extended {
        ((config >> 4) & 0x07) as usize + 1
    } else {
        0
    };
    let ctr_length = if ctr_extended {
        (config & 0x07) as usize + 1
    } else {
        0
    };
    let header_len = 1 + kid_length + ctr_length;
    if frame.len() < header_len {
        return Err(SframeError::MalformedHeader);
    }
    let mut offset = 1;
    let kid = if kid_extended {
        let value = decode_compact(&frame[offset..offset + kid_length])?;
        offset += kid_length;
        value
    } else {
        ((config >> 4) & 0x07) as u64
    };
    let ctr = if ctr_extended {
        decode_compact(&frame[offset..offset + ctr_length])?
    } else {
        (config & 0x07) as u64
    };
    if (kid_extended && kid < 8) || (ctr_extended && ctr < 8) {
        return Err(SframeError::MalformedHeader);
    }
    Ok(ParsedHeader {
        kid,
        ctr,
        header_len,
    })
}

fn compact_bytes(value: u64) -> Vec<u8> {
    let bytes = value.to_be_bytes();
    let first = bytes.iter().position(|byte| *byte != 0).unwrap_or(7);
    bytes[first..].to_vec()
}

fn decode_compact(bytes: &[u8]) -> Result<u64, SframeError> {
    if bytes.is_empty() || bytes.len() > 8 || (bytes.len() > 1 && bytes[0] == 0) {
        return Err(SframeError::MalformedHeader);
    }
    let mut output = [0_u8; 8];
    output[8 - bytes.len()..].copy_from_slice(bytes);
    Ok(u64::from_be_bytes(output))
}

#[derive(Debug, Error, PartialEq, Eq)]
pub enum SframeError {
    #[error("invalid SFrame base key")]
    InvalidKey,
    #[error("SFrame counter is exhausted")]
    CounterExhausted,
    #[error("malformed or non-canonical SFrame header")]
    MalformedHeader,
    #[error("SFrame key is not available")]
    UnknownKey,
    #[error("SFrame authentication failed")]
    AuthenticationFailed,
    #[error("SFrame counter was replayed or is outside the replay window")]
    Replay,
    #[error("input is too large")]
    InputTooLarge,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(value: &str) -> Vec<u8> {
        value
            .as_bytes()
            .chunks_exact(2)
            .map(|pair| u8::from_str_radix(std::str::from_utf8(pair).unwrap(), 16).unwrap())
            .collect()
    }

    #[test]
    fn rfc_9605_aes_128_gcm_vector() {
        let base_key = hex("000102030405060708090a0b0c0d0e0f");
        let metadata = hex("4945544620534672616d65205747");
        let plaintext = hex("64726166742d696574662d736672616d652d656e63");
        let expected = hex(
            "9901234567b7412c2513a1b66dbb48841bbaf17f598751176ad847681a69c6d0b091c07018ce4adb34eb",
        );
        let encryptor = Encryptor::new(0x0123, &base_key, MemoryCounterStore::default()).unwrap();
        let actual = encryptor
            .encrypt_with_consumed_counter(0x4567, &metadata, &plaintext)
            .unwrap();
        assert_eq!(actual, expected);
        let mut decryptor = Decryptor::new();
        decryptor.add_key(0x0123, &base_key).unwrap();
        assert_eq!(decryptor.decrypt(&metadata, &actual).unwrap(), plaintext);
    }

    #[test]
    fn header_boundaries_are_canonical() {
        for kid in [0, 7, 8, 255, 256, u64::MAX] {
            for ctr in [0, 7, 8, 255, 256, u64::MAX] {
                let header = encode_header(kid, ctr);
                let parsed = parse_header(&header).unwrap();
                assert_eq!((parsed.kid, parsed.ctr), (kid, ctr));
                assert_eq!(parsed.header_len, header.len());
            }
        }
        assert_eq!(
            parse_header(&[0x88, 0, 8]),
            Err(SframeError::MalformedHeader)
        );
    }

    #[test]
    fn replay_window_allows_reordering_once() {
        let key = [9_u8; 16];
        let encryptor = Encryptor::new(1, &key, MemoryCounterStore::default()).unwrap();
        let frame_10 = encryptor
            .encrypt_with_consumed_counter(10, b"aad", b"ten")
            .unwrap();
        let frame_8 = encryptor
            .encrypt_with_consumed_counter(8, b"aad", b"eight")
            .unwrap();
        let frame_200 = encryptor
            .encrypt_with_consumed_counter(200, b"aad", b"new")
            .unwrap();
        let mut decryptor = Decryptor::new();
        decryptor.add_key(1, &key).unwrap();
        assert_eq!(decryptor.decrypt(b"aad", &frame_10).unwrap(), b"ten");
        assert_eq!(decryptor.decrypt(b"aad", &frame_8).unwrap(), b"eight");
        assert_eq!(
            decryptor.decrypt(b"aad", &frame_8),
            Err(SframeError::Replay)
        );
        assert_eq!(decryptor.decrypt(b"aad", &frame_200).unwrap(), b"new");
        assert_eq!(
            decryptor.decrypt(b"aad", &frame_10),
            Err(SframeError::Replay)
        );
    }

    #[test]
    fn authentication_failure_does_not_consume_replay_slot() {
        let key = [4_u8; 16];
        let encryptor = Encryptor::new(2, &key, MemoryCounterStore::default()).unwrap();
        let frame = encryptor
            .encrypt_with_consumed_counter(3, b"aad", b"voice")
            .unwrap();
        let mut corrupt = frame.clone();
        *corrupt.last_mut().unwrap() ^= 1;
        let mut decryptor = Decryptor::new();
        decryptor.add_key(2, &key).unwrap();
        assert_eq!(
            decryptor.decrypt(b"aad", &corrupt),
            Err(SframeError::AuthenticationFailed)
        );
        assert_eq!(decryptor.decrypt(b"aad", &frame).unwrap(), b"voice");
    }
}
