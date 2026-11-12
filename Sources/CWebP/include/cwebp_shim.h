#ifndef CWEBP_SHIM_H
#define CWEBP_SHIM_H

#include <stddef.h>
#include <stdint.h>

size_t snapfeather_encode_webp_rgba(
    const uint8_t *rgba,
    int width,
    int height,
    int stride,
    float quality,
    uint8_t **output
);

void snapfeather_free_webp(uint8_t *ptr);

#endif
