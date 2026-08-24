//! Minimal, stateful JNI boundary for the 48 kHz mono Opus codec.
//!
//! Handles are owned by Kotlin and are never shared between encoder and decoder
//! instances. Every operation locks the native state so accidental calls from
//! two JVM threads cannot concurrently mutate libopus.

use audio_engine::{VoiceDecoder, VoiceEncoder, SAMPLES_PER_FRAME};
use jni::{
    objects::{JByteArray, JClass, JShortArray},
    sys::{jboolean, jbyteArray, jlong, jshortArray},
    JNIEnv,
};
use std::{ptr, sync::Mutex};

type EncoderHandle = Mutex<VoiceEncoder>;
type DecoderHandle = Mutex<VoiceDecoder>;

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
