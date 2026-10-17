#include "LibronxCompression.h"
#include "blast.h"

#include <limits.h>
#include <string.h>
#include <zlib.h>

#if defined(_WIN32)
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0600
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#else
#include <pthread.h>
#endif

struct input_context {
    const uint8_t *bytes;
    size_t length;
    size_t position;
};

struct output_context {
    uint8_t *bytes;
    size_t capacity;
    size_t written;
};

static unsigned supply_input(void *opaque, unsigned char **buffer) {
    struct input_context *context = opaque;
    size_t remaining = context->length - context->position;
    if (remaining == 0) {
        *buffer = NULL;
        return 0;
    }
    unsigned supplied = remaining > UINT_MAX ? UINT_MAX : (unsigned)remaining;
    /* Upstream blast borrows the bytes and never writes to the input buffer. */
    *buffer = (unsigned char *)(context->bytes + context->position);
    context->position += supplied;
    return supplied;
}

static int receive_output(void *opaque, unsigned char *buffer, unsigned length) {
    struct output_context *context = opaque;
    if ((size_t)length > context->capacity - context->written) {
        return 1;
    }
    if (length != 0) {
        memcpy(context->bytes + context->written, buffer, length);
        context->written += length;
    }
    return 0;
}

/* Upstream blast lazily constructs shared Huffman tables on its first call.
 * Warm them once using its published, noncommercial 13-byte test vector.
 * The platform once primitive establishes visibility before parallel decodes;
 * those calls each use their own input, output and decoder state.
 */
static int initialization_result = LIBRONX_EXPLODE_INITIALIZATION_FAILED;

static void initialize_tables(void) {
    static const uint8_t compressed[] = {0x00, 0x04, 0x82, 0x24,
                                         0x25, 0x8f, 0x80, 0x7f};
    static const uint8_t expected[] = "AIAIAIAIAIAIA";
    uint8_t decoded[sizeof(expected) - 1];
    struct input_context input = {compressed, sizeof(compressed), 0};
    struct output_context output = {decoded, sizeof(decoded), 0};
    int result = blast(supply_input, &input, receive_output, &output, NULL, NULL);
    if (result == 0 && output.written == sizeof(decoded) &&
        memcmp(decoded, expected, sizeof(decoded)) == 0) {
        initialization_result = 0;
    }
}

#if defined(_WIN32)
static INIT_ONCE initialization_once = INIT_ONCE_STATIC_INIT;

static BOOL CALLBACK initialize_tables_windows(PINIT_ONCE once, PVOID parameter,
                                               PVOID *context) {
    (void)once;
    (void)parameter;
    (void)context;
    initialize_tables();
    /* Complete even when the self-check fails; its failure stays observable. */
    return TRUE;
}

static int ensure_tables_initialized(void) {
    if (!InitOnceExecuteOnce(&initialization_once, initialize_tables_windows,
                             NULL, NULL)) {
        return LIBRONX_EXPLODE_INITIALIZATION_FAILED;
    }
    return initialization_result;
}
#else
static pthread_once_t initialization_once = PTHREAD_ONCE_INIT;

static int ensure_tables_initialized(void) {
    if (pthread_once(&initialization_once, initialize_tables) != 0) {
        return LIBRONX_EXPLODE_INITIALIZATION_FAILED;
    }
    return initialization_result;
}
#endif

static int explode_bounded(const uint8_t *input, size_t length,
                           uint8_t *output, size_t capacity, size_t *written,
                           int require_complete_input) {
    if (written == NULL) {
        return LIBRONX_EXPLODE_INVALID_ARGUMENT;
    }
    *written = 0;
    if ((length != 0 && input == NULL) ||
        (capacity != 0 && output == NULL)) {
        return LIBRONX_EXPLODE_INVALID_ARGUMENT;
    }
    if (length != 0 && capacity != 0) {
        uintptr_t input_address = (uintptr_t)input;
        uintptr_t output_address = (uintptr_t)output;
        if ((input_address <= output_address &&
             output_address - input_address < length) ||
            (output_address <= input_address &&
             input_address - output_address < capacity)) {
            return LIBRONX_EXPLODE_INVALID_ARGUMENT;
        }
    }
    if (ensure_tables_initialized() != 0) {
        return LIBRONX_EXPLODE_INITIALIZATION_FAILED;
    }
    struct input_context source = {input, length, 0};
    struct output_context destination = {output, capacity, 0};
    unsigned unused = 0;
    unsigned char *remaining = NULL;
    int result = blast(supply_input, &source, receive_output, &destination,
                       &unused, &remaining);
    *written = destination.written;
    if (result == 0 && require_complete_input &&
        (unused != 0 || source.position != source.length)) {
        return LIBRONX_COMPRESSION_TRAILING_DATA;
    }
    return result;
}

int libronx_explode(const uint8_t *input, size_t length,
                   uint8_t *output, size_t capacity, size_t *written) {
    return explode_bounded(input, length, output, capacity, written, 0);
}

int libronx_explode_exact(const uint8_t *input, size_t length,
                         uint8_t *output, size_t capacity, size_t *written) {
    return explode_bounded(input, length, output, capacity, written, 1);
}

int libronx_inflate_zlib(const uint8_t *input, size_t length,
                        uint8_t *output, size_t capacity, size_t *written) {
    if (written == NULL) return LIBRONX_EXPLODE_INVALID_ARGUMENT;
    *written = 0;
    if (length > UINT_MAX || capacity > UINT_MAX ||
        input == NULL || output == NULL || length == 0 || capacity == 0) {
        return LIBRONX_EXPLODE_INVALID_ARGUMENT;
    }
    uintptr_t source = (uintptr_t)input;
    uintptr_t destination = (uintptr_t)output;
    if ((source <= destination && destination - source < length) ||
        (destination <= source && source - destination < capacity)) {
        return LIBRONX_EXPLODE_INVALID_ARGUMENT;
    }
    uLongf output_length = (uLongf)capacity;
    uLong input_length = (uLong)length;
    int status = uncompress2(output, &output_length, input, &input_length);
    *written = (size_t)output_length;
    if (status == Z_OK && input_length != (uLong)length)
        return LIBRONX_COMPRESSION_TRAILING_DATA;
    return status;
}

/* EPUB ZIP uses raw DEFLATE and an independent CRC-32. */
int libronx_inflate_zip(const uint8_t *input, size_t length,
                       uint8_t *output, size_t capacity, uint32_t expected_crc) {
    if (!input || !output || length > UINT_MAX || capacity > UINT_MAX) return -100;
    z_stream stream = {0};
    stream.next_in = (Bytef *)input; stream.avail_in = (uInt)length;
    stream.next_out = output; stream.avail_out = (uInt)capacity;
    if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) return -101;
    int status = inflate(&stream, Z_FINISH);
    int valid = status == Z_STREAM_END && stream.total_in == length && stream.total_out == capacity;
    inflateEnd(&stream);
    if (!valid) return -102;
    return crc32(0, output, (uInt)capacity) == expected_crc ? 0 : -103;
}
uint32_t libronx_crc32(const uint8_t *bytes, size_t length) {
    return (uint32_t)crc32(0, bytes, (uInt)length);
}
