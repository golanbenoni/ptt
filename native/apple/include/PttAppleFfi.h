#ifndef PTT_APPLE_FFI_H
#define PTT_APPLE_FFI_H

#include <stddef.h>
#include <stdint.h>

size_t ptt_opus_samples_per_frame(void);
size_t ptt_opus_max_packet_bytes(void);
void *ptt_opus_encoder_create(void);
int32_t ptt_opus_encoder_encode(void *handle, const int16_t *pcm, size_t pcm_len,
                                uint8_t *output, size_t output_capacity);
void ptt_opus_encoder_destroy(void *handle);
void *ptt_opus_decoder_create(void);
int32_t ptt_opus_decoder_decode(void *handle, const uint8_t *packet, size_t packet_len,
                                int16_t *output, size_t output_capacity);
void ptt_opus_decoder_destroy(void *handle);

#endif
