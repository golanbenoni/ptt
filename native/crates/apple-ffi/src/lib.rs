//! Minimal stable C ABI shared by the iOS app and macOS Swift tests.

use audio_engine::{VoiceDecoder, VoiceEncoder, MAX_OPUS_PACKET_BYTES, SAMPLES_PER_FRAME};
use std::{ptr, slice};

const INVALID_ARGUMENT: i32 = -1;
const CODEC_ERROR: i32 = -2;

#[no_mangle]
pub extern "C" fn ptt_opus_samples_per_frame() -> usize {
    SAMPLES_PER_FRAME
}

#[no_mangle]
pub extern "C" fn ptt_opus_max_packet_bytes() -> usize {
    MAX_OPUS_PACKET_BYTES
}

#[no_mangle]
pub extern "C" fn ptt_opus_encoder_create() -> *mut VoiceEncoder {
    VoiceEncoder::new()
        .map(Box::new)
        .map(Box::into_raw)
        .unwrap_or(ptr::null_mut())
}

/// Returns encoded bytes or a negative status. The caller owns and serializes
/// access to `handle` and guarantees all pointers are valid for this call.
#[no_mangle]
pub unsafe extern "C" fn ptt_opus_encoder_encode(
    handle: *mut VoiceEncoder,
    pcm: *const i16,
    pcm_len: usize,
    output: *mut u8,
    output_capacity: usize,
) -> i32 {
    if handle.is_null()
        || pcm.is_null()
        || output.is_null()
        || pcm_len != SAMPLES_PER_FRAME
        || output_capacity < MAX_OPUS_PACKET_BYTES
    {
        return INVALID_ARGUMENT;
    }
    // SAFETY: validated above; lifetime and exclusive access are the caller's contract.
    let encoder = unsafe { &mut *handle };
    let samples = unsafe { slice::from_raw_parts(pcm, pcm_len) };
    match encoder.encode(samples) {
        Ok(packet) => {
            unsafe { ptr::copy_nonoverlapping(packet.as_ptr(), output, packet.len()) };
            packet.len() as i32
        }
        Err(_) => CODEC_ERROR,
    }
}

#[no_mangle]
pub unsafe extern "C" fn ptt_opus_encoder_destroy(handle: *mut VoiceEncoder) {
    if !handle.is_null() {
        drop(unsafe { Box::from_raw(handle) });
    }
}

#[no_mangle]
pub extern "C" fn ptt_opus_decoder_create() -> *mut VoiceDecoder {
    VoiceDecoder::new()
        .map(Box::new)
        .map(Box::into_raw)
        .unwrap_or(ptr::null_mut())
}

/// A null/empty packet invokes Opus packet-loss concealment.
#[no_mangle]
pub unsafe extern "C" fn ptt_opus_decoder_decode(
    handle: *mut VoiceDecoder,
    packet: *const u8,
    packet_len: usize,
    output: *mut i16,
    output_capacity: usize,
) -> i32 {
    if handle.is_null() || output.is_null() || output_capacity < SAMPLES_PER_FRAME {
        return INVALID_ARGUMENT;
    }
    if packet_len > MAX_OPUS_PACKET_BYTES || (packet.is_null() && packet_len != 0) {
        return INVALID_ARGUMENT;
    }
    let decoder = unsafe { &mut *handle };
    let encoded = if packet_len == 0 {
        None
    } else {
        Some(unsafe { slice::from_raw_parts(packet, packet_len) })
    };
    match decoder.decode(encoded) {
        Ok(samples) => {
            unsafe { ptr::copy_nonoverlapping(samples.as_ptr(), output, samples.len()) };
            samples.len() as i32
        }
        Err(_) => CODEC_ERROR,
    }
}

#[no_mangle]
pub unsafe extern "C" fn ptt_opus_decoder_destroy(handle: *mut VoiceDecoder) {
    if !handle.is_null() {
        drop(unsafe { Box::from_raw(handle) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn c_abi_round_trip_and_plc() {
        let encoder = ptt_opus_encoder_create();
        let decoder = ptt_opus_decoder_create();
        assert!(!encoder.is_null() && !decoder.is_null());
        let pcm = vec![1_000_i16; SAMPLES_PER_FRAME];
        let mut packet = vec![0_u8; MAX_OPUS_PACKET_BYTES];
        let encoded = unsafe {
            ptt_opus_encoder_encode(
                encoder,
                pcm.as_ptr(),
                pcm.len(),
                packet.as_mut_ptr(),
                packet.len(),
            )
        };
        assert!(encoded > 0 && encoded as usize <= MAX_OPUS_PACKET_BYTES);
        let mut output = vec![0_i16; SAMPLES_PER_FRAME];
        assert_eq!(
            unsafe {
                ptt_opus_decoder_decode(
                    decoder,
                    packet.as_ptr(),
                    encoded as usize,
                    output.as_mut_ptr(),
                    output.len(),
                )
            },
            SAMPLES_PER_FRAME as i32
        );
        assert_eq!(
            unsafe {
                ptt_opus_decoder_decode(decoder, ptr::null(), 0, output.as_mut_ptr(), output.len())
            },
            SAMPLES_PER_FRAME as i32
        );
        unsafe {
            ptt_opus_encoder_destroy(encoder);
            ptt_opus_decoder_destroy(decoder);
        }
    }
}
