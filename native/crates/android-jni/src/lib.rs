//! Minimal, stateful JNI boundary for the 48 kHz mono Opus codec.
//!
//! Handles are owned by Kotlin and are never shared between encoder and decoder
//! instances. Every operation locks the native state so accidental calls from
//! two JVM threads cannot concurrently mutate libopus.

use audio_engine::{AdaptiveJitterBuffer, Playout, VoiceDecoder, VoiceEncoder, SAMPLES_PER_FRAME};
use jni::{
    objects::{JByteArray, JClass, JShortArray},
    sys::{jboolean, jbyteArray, jlong, jshortArray},
    JNIEnv,
};
use std::{ptr, sync::Mutex};

type EncoderHandle = Mutex<VoiceEncoder>;
type DecoderHandle = Mutex<VoiceDecoder>;
type JitterHandle = Mutex<AdaptiveJitterBuffer>;

fn throw(env: &mut JNIEnv<'_>, class: &str, message: impl AsRef<str>) {
    let _ = env.throw_new(class, message.as_ref());
}

unsafe fn encoder<'a>(handle: jlong) -> Option<&'a EncoderHandle> {
    if handle == 0 {
        None
    } else {
        // SAFETY: handles are created by encoderCreate, owned by one Kotlin
        // object, and destroyed only after that object stops invoking JNI.
        unsafe { (handle as *const EncoderHandle).as_ref() }
    }
}

unsafe fn decoder<'a>(handle: jlong) -> Option<&'a DecoderHandle> {
    if handle == 0 {
        None
    } else {
        // SAFETY: same ownership contract as encoder().
        unsafe { (handle as *const DecoderHandle).as_ref() }
    }
}

unsafe fn jitter<'a>(handle: jlong) -> Option<&'a JitterHandle> {
    if handle == 0 {
        None
    } else {
        // SAFETY: handles are created and destroyed by NativeJitterBridge.
        unsafe { (handle as *const JitterHandle).as_ref() }
    }
}

#[no_mangle]
pub extern "system" fn Java_app_ptt_audio_NativeOpusBridge_encoderCreate(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
) -> jlong {
    match VoiceEncoder::new() {
        Ok(value) => Box::into_raw(Box::new(Mutex::new(value))) as jlong,
        Err(error) => {
            throw(
                &mut env,
                "java/lang/IllegalStateException",
                error.to_string(),
            );
            0
        }
    }
}

#[no_mangle]
pub extern "system" fn Java_app_ptt_audio_NativeOpusBridge_encoderEncode(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    handle: jlong,
    pcm: JShortArray<'_>,
) -> jbyteArray {
    let length = match env.get_array_length(&pcm) {
        Ok(value) => value as usize,
        Err(error) => {
            throw(
                &mut env,
                "java/lang/IllegalArgumentException",
                error.to_string(),
            );
            return ptr::null_mut();
        }
    };
    if length != SAMPLES_PER_FRAME {
        throw(
            &mut env,
            "java/lang/IllegalArgumentException",
            "Opus encoding requires exactly 960 PCM samples",
        );
        return ptr::null_mut();
    }
    let mut samples = vec![0_i16; length];
    if let Err(error) = env.get_short_array_region(&pcm, 0, &mut samples) {
        throw(
            &mut env,
            "java/lang/IllegalArgumentException",
            error.to_string(),
        );
        return ptr::null_mut();
    }
    // SAFETY: the Kotlin owner keeps this handle live for this synchronized call.
    let Some(state) = (unsafe { encoder(handle) }) else {
        throw(
            &mut env,
            "java/lang/IllegalStateException",
            "encoder is closed",
        );
        return ptr::null_mut();
    };
    let result = match state.lock() {
        Ok(mut value) => value.encode(&samples),
        Err(_) => {
            throw(
                &mut env,
                "java/lang/IllegalStateException",
                "encoder lock poisoned",
            );
            return ptr::null_mut();
        }
    };
    match result {
        Ok(packet) => match env.byte_array_from_slice(&packet) {
            Ok(result) => result.into_raw(),
            Err(error) => {
                throw(
                    &mut env,
                    "java/lang/IllegalStateException",
                    error.to_string(),
                );
                ptr::null_mut()
            }
        },
        Err(error) => {
            throw(
                &mut env,
                "java/lang/IllegalStateException",
                error.to_string(),
            );
            ptr::null_mut()
        }
    }
}

#[no_mangle]
pub extern "system" fn Java_app_ptt_audio_NativeOpusBridge_encoderDestroy(
    _env: JNIEnv<'_>,
    _class: JClass<'_>,
    handle: jlong,
) {
    if handle != 0 {
        // SAFETY: Kotlin closes each non-zero handle exactly once.
        drop(unsafe { Box::from_raw(handle as *mut EncoderHandle) });
    }
}

#[no_mangle]
pub extern "system" fn Java_app_ptt_audio_NativeOpusBridge_decoderCreate(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
) -> jlong {
    match VoiceDecoder::new() {
        Ok(value) => Box::into_raw(Box::new(Mutex::new(value))) as jlong,
        Err(error) => {
            throw(
                &mut env,
                "java/lang/IllegalStateException",
                error.to_string(),
            );
            0
        }
    }
}

#[no_mangle]
pub extern "system" fn Java_app_ptt_audio_NativeOpusBridge_decoderDecode(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    handle: jlong,
    packet: JByteArray<'_>,
    missing: jboolean,
) -> jshortArray {
    let bytes = if missing != 0 {
        None
    } else {
        match env.convert_byte_array(&packet) {
            Ok(value) if !value.is_empty() => Some(value),
            Ok(_) => {
                throw(
                    &mut env,
                    "java/lang/IllegalArgumentException",
                    "Opus packet is empty",
                );
                return ptr::null_mut();
            }
            Err(error) => {
                throw(
                    &mut env,
                    "java/lang/IllegalArgumentException",
                    error.to_string(),
                );
                return ptr::null_mut();
            }
        }
    };
    // SAFETY: the Kotlin owner keeps this handle live for this synchronized call.
    let Some(state) = (unsafe { decoder(handle) }) else {
        throw(
            &mut env,
            "java/lang/IllegalStateException",
            "decoder is closed",
        );
        return ptr::null_mut();
    };
    let decoded = match state.lock() {
        Ok(mut value) => value.decode(bytes.as_deref()),
        Err(_) => {
            throw(
                &mut env,
                "java/lang/IllegalStateException",
                "decoder lock poisoned",
            );
            return ptr::null_mut();
        }
    };
    match decoded {
        Ok(samples) => {
            let result = match env.new_short_array(samples.len() as i32) {
                Ok(value) => value,
                Err(error) => {
                    throw(
                        &mut env,
                        "java/lang/IllegalStateException",
                        error.to_string(),
                    );
                    return ptr::null_mut();
                }
            };
            if let Err(error) = env.set_short_array_region(&result, 0, &samples) {
                throw(
                    &mut env,
                    "java/lang/IllegalStateException",
                    error.to_string(),
                );
                return ptr::null_mut();
            }
            result.into_raw()
        }
        Err(error) => {
            throw(
                &mut env,
                "java/lang/IllegalStateException",
                error.to_string(),
            );
            ptr::null_mut()
        }
    }
}

#[no_mangle]
pub extern "system" fn Java_app_ptt_audio_NativeOpusBridge_decoderDestroy(
    _env: JNIEnv<'_>,
    _class: JClass<'_>,
    handle: jlong,
) {
    if handle != 0 {
        // SAFETY: Kotlin closes each non-zero handle exactly once.
        drop(unsafe { Box::from_raw(handle as *mut DecoderHandle) });
    }
}

#[no_mangle]
pub extern "system" fn Java_app_ptt_audio_NativeJitterBridge_create(
    _env: JNIEnv<'_>,
    _class: JClass<'_>,
) -> jlong {
    Box::into_raw(Box::new(Mutex::new(AdaptiveJitterBuffer::new()))) as jlong
}

#[no_mangle]
pub extern "system" fn Java_app_ptt_audio_NativeJitterBridge_push(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    handle: jlong,
    sequence: jlong,
    sent_timestamp_ms: jlong,
    arrival_ms: jlong,
    packet: JByteArray<'_>,
) {
    if !(0..=u32::MAX as jlong).contains(&sequence) || sent_timestamp_ms < 0 || arrival_ms < 0 {
        throw(
            &mut env,
            "java/lang/IllegalArgumentException",
            "invalid jitter timing metadata",
        );
        return;
    }
    let bytes = match env.convert_byte_array(&packet) {
        Ok(value) if !value.is_empty() => value,
        Ok(_) => {
            throw(
                &mut env,
                "java/lang/IllegalArgumentException",
                "jitter packet is empty",
            );
            return;
        }
        Err(error) => {
            throw(
                &mut env,
                "java/lang/IllegalArgumentException",
                error.to_string(),
            );
            return;
        }
    };
    let Some(state) = (unsafe { jitter(handle) }) else {
        throw(
            &mut env,
            "java/lang/IllegalStateException",
            "jitter buffer is closed",
        );
        return;
    };
    match state.lock() {
        Ok(mut value) => value.push(
            sequence as u32,
            sent_timestamp_ms as u64,
            arrival_ms as u64,
            bytes,
        ),
        Err(_) => throw(
            &mut env,
            "java/lang/IllegalStateException",
            "jitter lock poisoned",
        ),
    }
}

/// Returns null while buffering, an empty array for a missing packet, or the
/// next reordered packet.
#[no_mangle]
pub extern "system" fn Java_app_ptt_audio_NativeJitterBridge_pop(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    handle: jlong,
) -> jbyteArray {
    let Some(state) = (unsafe { jitter(handle) }) else {
        throw(
            &mut env,
            "java/lang/IllegalStateException",
            "jitter buffer is closed",
        );
        return ptr::null_mut();
    };
    let result = match state.lock() {
        Ok(mut value) => value.pop(),
        Err(_) => {
            throw(
                &mut env,
                "java/lang/IllegalStateException",
                "jitter lock poisoned",
            );
            return ptr::null_mut();
        }
    };
    match result {
        Playout::Buffering => ptr::null_mut(),
        Playout::Missing => env
            .new_byte_array(0)
            .map(|value| value.into_raw())
            .unwrap_or(ptr::null_mut()),
        Playout::Packet(bytes) => env
            .byte_array_from_slice(&bytes)
            .map(|value| value.into_raw())
            .unwrap_or(ptr::null_mut()),
    }
}

#[no_mangle]
pub extern "system" fn Java_app_ptt_audio_NativeJitterBridge_targetDelayMs(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    handle: jlong,
) -> jlong {
    let Some(state) = (unsafe { jitter(handle) }) else {
        throw(
            &mut env,
            "java/lang/IllegalStateException",
            "jitter buffer is closed",
        );
        return 0;
    };
    match state.lock() {
        Ok(value) => value.target_delay_ms() as jlong,
        Err(_) => {
            throw(
                &mut env,
                "java/lang/IllegalStateException",
                "jitter lock poisoned",
            );
            0
        }
    }
}

#[no_mangle]
pub extern "system" fn Java_app_ptt_audio_NativeJitterBridge_flush(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    handle: jlong,
) {
    let Some(state) = (unsafe { jitter(handle) }) else {
        throw(
            &mut env,
            "java/lang/IllegalStateException",
            "jitter buffer is closed",
        );
        return;
    };
    match state.lock() {
        Ok(mut value) => value.flush(),
        Err(_) => throw(
            &mut env,
            "java/lang/IllegalStateException",
            "jitter lock poisoned",
        ),
    }
}

#[no_mangle]
pub extern "system" fn Java_app_ptt_audio_NativeJitterBridge_destroy(
    _env: JNIEnv<'_>,
    _class: JClass<'_>,
    handle: jlong,
) {
    if handle != 0 {
        // SAFETY: Kotlin closes every non-zero jitter handle once.
        drop(unsafe { Box::from_raw(handle as *mut JitterHandle) });
    }
}
