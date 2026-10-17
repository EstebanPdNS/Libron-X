#ifndef LIBRONX_COMPRESSION_H
#define LIBRONX_COMPRESSION_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    LIBRONX_EXPLODE_INVALID_ARGUMENT = -100,
    LIBRONX_EXPLODE_INITIALIZATION_FAILED = -101,
    LIBRONX_COMPRESSION_TRAILING_DATA = -102
};

/* Decode one PKWARE DCL stream into a caller-owned buffer.
 * This is the DCL format, not PKZIP's different "implode" method.
 *
 * Return codes from upstream blast are preserved:
 *   0 success; 1 insufficient output capacity; 2 truncated input;
 *  -1 invalid literal flag; -2 invalid dictionary size; -3 invalid distance.
 * The two -100/-101 codes above report wrapper errors.
 *
 * `written` must point to a separate caller-owned size_t and is required.
 * It is set to the number of bytes actually copied,
 * including partial output on failure. Callers must discard partial output
 * when the return value is nonzero and verify their expected decoded size.
 * A NULL data pointer is permitted only when its corresponding size is zero.
 * Input and output buffers must not overlap. No allocation or file access is
 * performed; output never exceeds `capacity`. Concurrent calls are supported.
 */
int libronx_explode(const uint8_t *input, size_t length,
                   uint8_t *output, size_t capacity, size_t *written);

/* Decode exactly one DCL stream with the same bounded I/O contract as above.
 * Return LIBRONX_COMPRESSION_TRAILING_DATA when whole bytes remain after its
 * terminator. Padding bits in the final consumed byte are permitted. This is a
 * stricter framing API; libronx_explode retains its existing behavior.
 * Discard the output on every nonzero return, including trailing data.
 */
int libronx_explode_exact(const uint8_t *input, size_t length,
                         uint8_t *output, size_t capacity, size_t *written);

/* Inflate a zlib-wrapped stream, including its header and Adler-32 trailer.
 * Return 0 on success, a zlib error (<0) on malformed/truncated input or an
 * insufficient output buffer, -100 for invalid arguments, or -102 for bytes
 * following the zlib terminator (LIBRONX_COMPRESSION_TRAILING_DATA).
 * Input/output sizes are limited to UINT_MAX; both buffers and `written` are
 * required and the buffer sizes must be nonzero. Buffers must not overlap;
 * `written` must point to a separate caller-owned size_t.
 * The caller must verify the decoded length and discard output on failure.
 * `written` reports bytes copied, including partial output on failure.
 * These calls do not access files; output never exceeds `capacity` and
 * concurrent calls are supported.
 */
int libronx_inflate_zlib(const uint8_t *input, size_t length,
                        uint8_t *output, size_t capacity, size_t *written);

int libronx_deflate_zlib(const uint8_t *input, size_t length, uint8_t *output, size_t capacity, size_t *written);

int libronx_inflate_zip(const uint8_t *input, size_t length, uint8_t *output, size_t capacity, uint32_t expected_crc);
uint32_t libronx_crc32(const uint8_t *bytes, size_t length);

#ifdef __cplusplus
}
#endif

#endif
