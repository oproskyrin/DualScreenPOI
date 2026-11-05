#ifndef VTENCODER_SHIM_H
#define VTENCODER_SHIM_H

#include <stdint.h>
#include <stddef.h>
#include <CoreVideo/CoreVideo.h>

#ifdef __cplusplus
extern "C" {
#endif

// Hardware HEVC encoder (VideoToolbox), realtime/low-latency. Emits
// Annex-B access units: VPS/SPS/PPS inlined on keyframes.
// pts is in seconds (double).

typedef void (*vtenc_packet_cb)(void *ctx,
                                const uint8_t *data, size_t len,
                                double ptsSeconds, int isKey);

// Returns opaque handle or NULL on failure.
void *vtenc_create(uint32_t width, uint32_t height,
                   uint32_t fps, uint32_t bitrateBps,
                   vtenc_packet_cb cb, void *ctx);

// Returns 0 on success (encode submitted), non-zero on error.
int vtenc_encode(void *enc, CVPixelBufferRef pixelBuffer,
                 double ptsSeconds, int forceKeyframe);

void vtenc_destroy(void *enc);

#ifdef __cplusplus
}
#endif

#endif /* VTENCODER_SHIM_H */
