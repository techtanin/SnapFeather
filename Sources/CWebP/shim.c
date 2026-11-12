#include "cwebp_shim.h"
#include <webp/encode.h>

size_t snapfeather_encode_webp_rgba(
    const uint8_t *rgba,
    int width,
    int height,
    int stride,
    float quality,
    uint8_t **output
) {
    return WebPEncodeRGBA(rgba, width, height, stride, quality, output);
}

void snapfeather_free_webp(uint8_t *ptr) {
    WebPFree(ptr);
}
