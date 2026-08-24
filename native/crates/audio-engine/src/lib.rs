//! 48 kHz mono Opus voice codec, level/VAD analysis, PLC, and adaptive jitter.
//!
//! Capture, playback, acoustic echo cancellation, and noise suppression remain
//! platform-native so Android and iOS can use their hardware audio effects.

use opus::{Application, Bitrate, Channels, Decoder, Encoder};
use std::collections::BTreeMap;
use thiserror::Error;

pub const SAMPLE_RATE_HZ: u32 = 48_000;
pub const FRAME_DURATION_MS: usize = 20;
pub const SAMPLES_PER_FRAME: usize = SAMPLE_RATE_HZ as usize * FRAME_DURATION_MS / 1_000;
/// Leaves room for the frozen 160-byte UDP envelope, SFrame header/tag, and
/// authenticated routing header while retaining constrained 24 kbit/s VBR.
pub const MAX_OPUS_PACKET_BYTES: usize = 98;
const MAX_BUFFERED_PACKETS: usize = 512;
const MAX_SEQUENCE_AHEAD: u64 = 2_048;

pub struct VoiceEncoder {
    encoder: Encoder,
}

impl VoiceEncoder {
    pub fn new() -> Result<Self, AudioError> {
        let mut encoder = Encoder::new(SAMPLE_RATE_HZ, Channels::Mono, Application::Voip)?;
        encoder.set_bitrate(Bitrate::Bits(24_000))?;
        encoder.set_vbr(true)?;
        encoder.set_vbr_constraint(true)?;
        encoder.set_inband_fec(true)?;
        encoder.set_packet_loss_perc(10)?;
        Ok(Self { encoder })
    }

    pub fn set_expected_packet_loss(&mut self, percent: u8) -> Result<(), AudioError> {
        if percent > 100 {
            return Err(AudioError::InvalidPacketLoss);
        }
        self.encoder.set_packet_loss_perc(percent as i32)?;
        Ok(())
    }

    pub fn encode(&mut self, pcm: &[i16]) -> Result<Vec<u8>, AudioError> {
        if pcm.len() != SAMPLES_PER_FRAME {
            return Err(AudioError::InvalidFrameSize);
        }
        Ok(self.encoder.encode_vec(pcm, MAX_OPUS_PACKET_BYTES)?)
    }
}

pub struct VoiceDecoder {
    decoder: Decoder,
}

impl VoiceDecoder {
    pub fn new() -> Result<Self, AudioError> {
        Ok(Self {
            decoder: Decoder::new(SAMPLE_RATE_HZ, Channels::Mono)?,
        })
    }

    /// Decodes a packet, or invokes Opus packet-loss concealment for `None`.
    pub fn decode(&mut self, packet: Option<&[u8]>) -> Result<Vec<i16>, AudioError> {
        let mut pcm = vec![0_i16; SAMPLES_PER_FRAME];
        let samples = self
            .decoder
            .decode(packet.unwrap_or_default(), &mut pcm, false)?;
        pcm.truncate(samples);
        Ok(pcm)
    }

    /// Recovers a missing frame using FEC data from the following packet.
    pub fn decode_fec(&mut self, following_packet: &[u8]) -> Result<Vec<i16>, AudioError> {
        let mut pcm = vec![0_i16; SAMPLES_PER_FRAME];
        let samples = self.decoder.decode(following_packet, &mut pcm, true)?;
        pcm.truncate(samples);
        Ok(pcm)
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct AudioLevel {
    pub peak: f32,
    pub rms: f32,
    pub dbfs: f32,
}

pub fn measure_level(pcm: &[i16]) -> AudioLevel {
    if pcm.is_empty() {
        return AudioLevel {
            peak: 0.0,
            rms: 0.0,
            dbfs: -96.0,
        };
    }
    let scale = i16::MAX as f64;
    let mut squares = 0.0_f64;
    let mut peak = 0_i32;
    for sample in pcm {
        let magnitude = i32::from(*sample).unsigned_abs() as i32;
        peak = peak.max(magnitude);
        let normalized = f64::from(*sample) / scale;
        squares += normalized * normalized;
    }
    let rms = (squares / pcm.len() as f64).sqrt() as f32;
    AudioLevel {
        peak: (peak as f32 / i16::MAX as f32).min(1.0),
        rms,
        dbfs: if rms <= f32::EPSILON {
            -96.0
        } else {
            (20.0 * rms.log10()).max(-96.0)
        },
    }
}

pub struct VoiceActivityDetector {
    noise_floor_dbfs: f32,
    hangover: u8,
}

impl VoiceActivityDetector {
    pub fn new() -> Self {
        Self {
            noise_floor_dbfs: -60.0,
            hangover: 0,
        }
    }

    pub fn update(&mut self, pcm: &[i16]) -> bool {
        let level = measure_level(pcm).dbfs;
        let threshold = (self.noise_floor_dbfs + 12.0).clamp(-50.0, -28.0);
        if level >= threshold {
            self.hangover = 10;
            true
        } else if self.hangover > 0 {
            self.hangover -= 1;
            true
        } else {
            self.noise_floor_dbfs = self.noise_floor_dbfs * 0.98 + level * 0.02;
            false
        }
    }
}

impl Default for VoiceActivityDetector {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Playout {
    Packet(Vec<u8>),
    Missing,
    Buffering,
}

#[derive(Debug)]
pub struct AdaptiveJitterBuffer {
    packets: BTreeMap<u64, Vec<u8>>,
    next_sequence: Option<u64>,
    highest_sequence: Option<u64>,
    previous_transit_ms: Option<i64>,
    jitter_ms: f64,
    target_frames: usize,
    started: bool,
}

impl AdaptiveJitterBuffer {
    pub fn new() -> Self {
        Self {
            packets: BTreeMap::new(),
            next_sequence: None,
            highest_sequence: None,
            previous_transit_ms: None,
            jitter_ms: 0.0,
            target_frames: 3,
            started: false,
        }
    }

    pub fn target_delay_ms(&self) -> usize {
        self.target_frames * FRAME_DURATION_MS
    }

    pub fn push(
        &mut self,
        sequence: u32,
        sent_timestamp_ms: u64,
        arrival_ms: u64,
        packet: Vec<u8>,
    ) {
        let extended = extend_sequence(self.highest_sequence, sequence);
        if self
            .highest_sequence
            .is_some_and(|highest| extended > highest.saturating_add(MAX_SEQUENCE_AHEAD))
        {
            return;
        }
        if self.next_sequence.is_some_and(|next| extended < next) {
            return;
        }
        self.highest_sequence = Some(
            self.highest_sequence
                .map_or(extended, |old| old.max(extended)),
        );
        self.next_sequence.get_or_insert(extended);
        self.packets.entry(extended).or_insert(packet);
        while self.packets.len() > MAX_BUFFERED_PACKETS {
            if let Some(oldest) = self.packets.keys().next().copied() {
                self.packets.remove(&oldest);
            }
        }

        let transit = arrival_ms as i64 - sent_timestamp_ms as i64;
        if let Some(previous) = self.previous_transit_ms {
            let delta = (transit - previous).unsigned_abs() as f64;
            self.jitter_ms += (delta - self.jitter_ms) / 16.0;
            let desired =
                ((40.0 + self.jitter_ms * 2.0) / FRAME_DURATION_MS as f64).ceil() as usize;
            self.target_frames = desired.clamp(2, 10);
        }
        self.previous_transit_ms = Some(transit);
    }

    pub fn pop(&mut self) -> Playout {
        let Some(next) = self.next_sequence else {
            return Playout::Buffering;
        };
        let highest = self.highest_sequence.unwrap_or(next);
        if !self.started {
            if highest.saturating_sub(next) + 1 < self.target_frames as u64 {
                return Playout::Buffering;
            }
            self.started = true;
        }
        self.next_sequence = Some(next + 1);
        self.packets
            .remove(&next)
            .map(Playout::Packet)
            .unwrap_or(Playout::Missing)
    }
}

impl Default for AdaptiveJitterBuffer {
    fn default() -> Self {
        Self::new()
    }
}

fn extend_sequence(highest: Option<u64>, sequence: u32) -> u64 {
    let Some(highest) = highest else {
        return u64::from(sequence);
    };
    let base = highest & !0xffff_ffff;
    let candidate = base | u64::from(sequence);
    if candidate + (1_u64 << 31) < highest {
        candidate + (1_u64 << 32)
    } else if candidate > highest + (1_u64 << 31) {
        candidate.checked_sub(1_u64 << 32).unwrap_or(candidate)
    } else {
        candidate
    }
}

#[derive(Debug, Error)]
pub enum AudioError {
    #[error("Opus codec error: {0}")]
    Opus(#[from] opus::Error),
    #[error("a voice frame must contain exactly 20 ms of 48 kHz mono PCM")]
    InvalidFrameSize,
    #[error("packet loss percentage must be between 0 and 100")]
    InvalidPacketLoss,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn opus_round_trip_and_plc_produce_twenty_millisecond_frames() {
        let pcm: Vec<i16> = (0..SAMPLES_PER_FRAME)
            .map(|index| {
                let phase = index as f32 * 2.0 * std::f32::consts::PI * 440.0 / 48_000.0;
                (phase.sin() * 12_000.0) as i16
            })
            .collect();
        let mut encoder = VoiceEncoder::new().unwrap();
        let packet = encoder.encode(&pcm).unwrap();
        assert!(!packet.is_empty() && packet.len() <= MAX_OPUS_PACKET_BYTES);
        let mut decoder = VoiceDecoder::new().unwrap();
        assert_eq!(
            decoder.decode(Some(&packet)).unwrap().len(),
            SAMPLES_PER_FRAME
        );
        assert_eq!(decoder.decode(None).unwrap().len(), SAMPLES_PER_FRAME);
    }

    #[test]
    fn constrained_voice_packets_always_fit_the_frozen_udp_envelope() {
        let mut encoder = VoiceEncoder::new().unwrap();
        let mut state = 0x1234_5678_u32;
        for frame_index in 0..1_000 {
            let pcm: Vec<i16> = (0..SAMPLES_PER_FRAME)
                .map(|sample_index| {
                    state = state.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
                    let noise = (state >> 16) as i16;
                    if frame_index % 3 == 0 {
                        noise
                    } else {
                        let phase = (frame_index * SAMPLES_PER_FRAME + sample_index) as f32
                            * 2.0
                            * std::f32::consts::PI
                            * 997.0
                            / SAMPLE_RATE_HZ as f32;
                        (phase.sin() * 30_000.0) as i16
                    }
                })
                .collect();
            let packet = encoder.encode(&pcm).unwrap();
            assert!(!packet.is_empty() && packet.len() <= MAX_OPUS_PACKET_BYTES);
        }
    }

    #[test]
    fn jitter_buffer_reorders_and_reports_loss() {
        let mut jitter = AdaptiveJitterBuffer::new();
        jitter.push(10, 0, 50, vec![10]);
        jitter.push(12, 40, 100, vec![12]);
        jitter.push(11, 20, 72, vec![11]);
        assert_eq!(jitter.pop(), Playout::Packet(vec![10]));
        assert_eq!(jitter.pop(), Playout::Packet(vec![11]));
        jitter.push(14, 80, 150, vec![14]);
        assert_eq!(jitter.pop(), Playout::Packet(vec![12]));
        jitter.push(15, 100, 170, vec![15]);
        assert_eq!(jitter.pop(), Playout::Missing);
        assert_eq!(jitter.pop(), Playout::Packet(vec![14]));
    }

    #[test]
    fn level_and_vad_distinguish_voice_from_silence() {
        let silence = [0_i16; SAMPLES_PER_FRAME];
        let voice = [8_000_i16; SAMPLES_PER_FRAME];
        assert_eq!(measure_level(&silence).dbfs, -96.0);
        assert!(measure_level(&voice).dbfs > -20.0);
        let mut vad = VoiceActivityDetector::new();
        assert!(!vad.update(&silence));
        assert!(vad.update(&voice));
        assert!(vad.update(&silence));
    }
}
