//! Minimal stable C ABI shared by the iOS app and macOS Swift tests.

use audio_engine::{
    AdaptiveJitterBuffer, Playout, VoiceDecoder, VoiceEncoder, MAX_OPUS_PACKET_BYTES,
    SAMPLES_PER_FRAME,
};
use std::{ptr, slice};

const INVALID_ARGUMENT: i32 = -1;
const CODEC_ERROR: i32 = -2;
const JITTER_BUFFERING: i32 = 0;
const JITTER_MISSING: i32 = 1;
const JITTER_PACKET: i32 = 2;

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
///
/// # Safety
///
/// `handle` must be a live encoder returned by `ptt_opus_encoder_create` with
/// exclusive access for the call. `pcm` must reference `pcm_len` initialized
/// samples, and `output` must reference `output_capacity` writable bytes.
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

/// Releases an encoder allocated by `ptt_opus_encoder_create`.
///
/// # Safety
///
/// `handle` must be null or a live, uniquely owned encoder pointer returned by
/// `ptt_opus_encoder_create`. A non-null pointer may be destroyed only once.
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
///
/// # Safety
///
/// `handle` must be a live decoder returned by `ptt_opus_decoder_create` with
/// exclusive access for the call. A non-empty `packet` must reference
/// `packet_len` readable bytes. `output` must reference `output_capacity`
/// writable samples.
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

/// Releases a decoder allocated by `ptt_opus_decoder_create`.
///
/// # Safety
///
/// `handle` must be null or a live, uniquely owned decoder pointer returned by
/// `ptt_opus_decoder_create`. A non-null pointer may be destroyed only once.
#[no_mangle]
pub unsafe extern "C" fn ptt_opus_decoder_destroy(handle: *mut VoiceDecoder) {
    if !handle.is_null() {
        drop(unsafe { Box::from_raw(handle) });
    }
}

#[no_mangle]
pub extern "C" fn ptt_jitter_create() -> *mut AdaptiveJitterBuffer {
    Box::into_raw(Box::new(AdaptiveJitterBuffer::new()))
}

/// Adds one encoded packet to the adaptive jitter buffer.
///
/// # Safety
///
/// `handle` must be a live jitter buffer returned by `ptt_jitter_create` with
/// exclusive access for the call. `packet` must reference `packet_len`
/// initialized bytes.
#[no_mangle]
pub unsafe extern "C" fn ptt_jitter_push(
    handle: *mut AdaptiveJitterBuffer,
    sequence: u32,
    sent_timestamp_ms: u64,
    arrival_ms: u64,
    packet: *const u8,
    packet_len: usize,
) -> i32 {
    if handle.is_null() || packet.is_null() || packet_len == 0 {
        return INVALID_ARGUMENT;
    }
    let jitter = unsafe { &mut *handle };
    let bytes = unsafe { slice::from_raw_parts(packet, packet_len) };
    jitter.push(sequence, sent_timestamp_ms, arrival_ms, bytes.to_vec());
    0
}

/// Returns `JITTER_BUFFERING`, `JITTER_MISSING`, or `JITTER_PACKET`. For a
/// packet result, `output_len` receives the copied byte count.
///
/// # Safety
///
/// `handle` must be a live jitter buffer with exclusive access. `output` must
/// reference `output_capacity` writable bytes, and `output_len` must reference
/// one writable `usize`.
#[no_mangle]
pub unsafe extern "C" fn ptt_jitter_pop(
    handle: *mut AdaptiveJitterBuffer,
    output: *mut u8,
    output_capacity: usize,
    output_len: *mut usize,
) -> i32 {
    if handle.is_null() || output.is_null() || output_len.is_null() {
        return INVALID_ARGUMENT;
    }
    unsafe { *output_len = 0 };
    match unsafe { &mut *handle }.pop() {
        Playout::Buffering => JITTER_BUFFERING,
        Playout::Missing => JITTER_MISSING,
        Playout::Packet(bytes) => {
            if bytes.len() > output_capacity {
                return INVALID_ARGUMENT;
            }
            unsafe {
                ptr::copy_nonoverlapping(bytes.as_ptr(), output, bytes.len());
                *output_len = bytes.len();
            }
            JITTER_PACKET
        }
    }
}

/// Returns the current target delay for a live jitter buffer.
///
/// # Safety
///
/// `handle` must be null or point to a live jitter buffer that remains valid
/// and is not mutably accessed for the duration of this call.
#[no_mangle]
pub unsafe extern "C" fn ptt_jitter_target_delay_ms(handle: *const AdaptiveJitterBuffer) -> u64 {
    if handle.is_null() {
        0
    } else {
        unsafe { &*handle }.target_delay_ms() as u64
    }
}

/// Flushes a live jitter buffer so a short transmission can begin playout.
///
/// # Safety
///
/// `handle` must point to a live jitter buffer with exclusive access for the
/// duration of this call.
#[no_mangle]
pub unsafe extern "C" fn ptt_jitter_flush(handle: *mut AdaptiveJitterBuffer) -> i32 {
    if handle.is_null() {
        return INVALID_ARGUMENT;
    }
    unsafe { &mut *handle }.flush();
    0
}

/// Releases a jitter buffer allocated by `ptt_jitter_create`.
///
/// # Safety
///
/// `handle` must be null or a live, uniquely owned pointer returned by
/// `ptt_jitter_create`. A non-null pointer may be destroyed only once.
#[no_mangle]
pub unsafe extern "C" fn ptt_jitter_destroy(handle: *mut AdaptiveJitterBuffer) {
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

    #[test]
    fn c_abi_jitter_reorders_flushes_and_reports_loss() {
        let jitter = ptt_jitter_create();
        assert!(!jitter.is_null());
        let five = [5_u8];
        unsafe {
            assert_eq!(ptt_jitter_push(jitter, 5, 0, 10, five.as_ptr(), 1), 0);
        }
        let mut output = [0_u8; 8];
        let mut output_len = 0;
        assert_eq!(
            unsafe { ptt_jitter_pop(jitter, output.as_mut_ptr(), output.len(), &mut output_len) },
            JITTER_BUFFERING
        );
        assert_eq!(unsafe { ptt_jitter_flush(jitter) }, 0);
        let seven = [7_u8];
        assert_eq!(
            unsafe { ptt_jitter_push(jitter, 7, 40, 12, seven.as_ptr(), 1) },
            0
        );
        assert_eq!(
            unsafe { ptt_jitter_pop(jitter, output.as_mut_ptr(), output.len(), &mut output_len) },
            JITTER_PACKET
        );
        assert_eq!(&output[..output_len], &five);
        assert_eq!(
            unsafe { ptt_jitter_pop(jitter, output.as_mut_ptr(), output.len(), &mut output_len) },
            JITTER_MISSING
        );
        assert_eq!(
            unsafe { ptt_jitter_pop(jitter, output.as_mut_ptr(), output.len(), &mut output_len) },
            JITTER_PACKET
        );
        assert_eq!(&output[..output_len], &seven);
        unsafe { ptt_jitter_destroy(jitter) };
    }
}
