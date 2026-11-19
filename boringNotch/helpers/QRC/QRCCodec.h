#ifndef SEVEN_QRC_CODEC_H
#define SEVEN_QRC_CODEC_H

#include <stddef.h>
#include <stdint.h>

size_t seven_decode_qrc(uint8_t *input, size_t input_size, uint8_t *output, size_t output_capacity);

#endif
