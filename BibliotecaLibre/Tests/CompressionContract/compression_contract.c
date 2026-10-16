/* Synthetic and upstream-public fixtures; no proprietary book content. */
#include "LibronxCompression.h"

#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0600
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#else
#include <pthread.h>
#endif

#define THREAD_COUNT 16
#define DECODES_PER_THREAD 1000

static const uint8_t dcl[] = {0x00, 0x04, 0x82, 0x24, 0x25, 0x8f, 0x80, 0x7f};
static const uint8_t dcl_plain[] = "AIAIAIAIAIAIA";
/* Python's zlib.compress() of the bytes below, including embedded NUL. */
static const uint8_t zlib_stream[] = {
    120,156,243,201,76,42,202,207,211,141,80,40,200,47,42,73,76,202,73,85,
    72,206,47,74,101,96,96,100,98,102,97,101,99,231,224,228,226,230,225,
    229,227,23,16,20,18,22,17,21,19,151,144,148,146,150,145,149,147,7,0,
    128,89,10,30
};
static const uint8_t zlib_plain[] = {
    'L','i','b','r','o','n','-','X',' ','p','o','r','t','a','b','l','e',' ',
    'c','o','r','e',0,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,
    19,20,21,22,23,24,25,26,27,28,29,30,31
};
static unsigned assertions, failures;

#define CHECK(condition) do { \
    assertions++; \
    if (!(condition)) { \
        failures++; \
        fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #condition); \
    } \
} while (0)

struct worker_result { unsigned failures; };

#if defined(_WIN32)
static HANDLE start_gate;
static DWORD WINAPI decode_worker(LPVOID opaque) {
    struct worker_result *result = opaque;
    if (WaitForSingleObject(start_gate, 30000) != WAIT_OBJECT_0) {
        result->failures++;
        return 0;
    }
#else
static pthread_mutex_t gate_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t gate_condition = PTHREAD_COND_INITIALIZER;
static int start_gate;
static void *decode_worker(void *opaque) {
    struct worker_result *result = opaque;
    pthread_mutex_lock(&gate_mutex);
    while (!start_gate) pthread_cond_wait(&gate_condition, &gate_mutex);
    pthread_mutex_unlock(&gate_mutex);
#endif
    for (unsigned i = 0; i < DECODES_PER_THREAD; i++) {
        uint8_t buffer[sizeof(zlib_plain) + 2];
        size_t written = 999;
        memset(buffer, 0xa5, sizeof(buffer));
        int dcl_status = i % 2 == 0
            ? libronx_explode(dcl, sizeof(dcl), buffer + 1,
                              sizeof(dcl_plain) - 1, &written)
            : libronx_explode_exact(dcl, sizeof(dcl), buffer + 1,
                                    sizeof(dcl_plain) - 1, &written);
        if (dcl_status != 0 ||
            written != sizeof(dcl_plain) - 1 ||
            memcmp(buffer + 1, dcl_plain, written) != 0 ||
            buffer[0] != 0xa5 || buffer[sizeof(dcl_plain)] != 0xa5) {
            result->failures++;
        }
        memset(buffer, 0xa5, sizeof(buffer));
        if (libronx_inflate_zlib(zlib_stream, sizeof(zlib_stream), buffer + 1,
                                 sizeof(zlib_plain), &written) != 0 ||
            written != sizeof(zlib_plain) ||
            memcmp(buffer + 1, zlib_plain, written) != 0 ||
            buffer[0] != 0xa5 || buffer[sizeof(buffer) - 1] != 0xa5) {
            result->failures++;
        }
    }
#if defined(_WIN32)
    return 0;
#else
    return NULL;
#endif
}

/* This runs before any sequential decode, exercising cold initialization. */
static void check_parallel_first_calls(void) {
    struct worker_result results[THREAD_COUNT] = {{0}};
    unsigned created = 0;
#if defined(_WIN32)
    HANDLE workers[THREAD_COUNT];
    start_gate = CreateEventW(NULL, TRUE, FALSE, NULL);
    CHECK(start_gate != NULL);
    if (start_gate == NULL) return;
    for (unsigned i = 0; i < THREAD_COUNT; i++) {
        workers[i] = CreateThread(NULL, 0, decode_worker, &results[i], 0, NULL);
        if (workers[i] == NULL) break;
        created++;
    }
    CHECK(SetEvent(start_gate) != 0);
    for (unsigned i = 0; i < created; i++) {
        DWORD status = WaitForSingleObject(workers[i], 30000);
        CHECK(status == WAIT_OBJECT_0);
        /* A timeout is a hard failure; workers still own stack addresses. */
        if (status != WAIT_OBJECT_0) ExitProcess(1);
        CHECK(CloseHandle(workers[i]) != 0);
    }
    CHECK(CloseHandle(start_gate) != 0);
#else
    pthread_t workers[THREAD_COUNT];
    for (unsigned i = 0; i < THREAD_COUNT; i++) {
        if (pthread_create(&workers[i], NULL, decode_worker, &results[i]) != 0)
            break;
        created++;
    }
    pthread_mutex_lock(&gate_mutex);
    start_gate = 1;
    pthread_cond_broadcast(&gate_condition);
    pthread_mutex_unlock(&gate_mutex);
    for (unsigned i = 0; i < created; i++) {
        int status = pthread_join(workers[i], NULL);
        CHECK(status == 0);
        if (status != 0) exit(EXIT_FAILURE);
    }
#endif
    CHECK(created == THREAD_COUNT);
    for (unsigned i = 0; i < created; i++) CHECK(results[i].failures == 0);
}

static void check_dcl(void) {
    uint8_t buffer[64];
    size_t written;
    memset(buffer, 0xa5, sizeof(buffer));
    CHECK(libronx_explode(dcl, sizeof(dcl), buffer + 1, 13, &written) == 0);
    CHECK(written == 13 && memcmp(buffer + 1, dcl_plain, 13) == 0);
    CHECK(buffer[0] == 0xa5 && buffer[14] == 0xa5);

    memset(buffer, 0xa5, sizeof(buffer));
    CHECK(libronx_explode(dcl, sizeof(dcl), buffer + 1, 12, &written) == 1);
    CHECK(written <= 12 && buffer[0] == 0xa5 && buffer[13] == 0xa5);
    for (size_t length = 0; length < sizeof(dcl); length++) {
        CHECK(libronx_explode(dcl, length, buffer, sizeof(buffer), &written) == 2);
        CHECK(written <= sizeof(buffer));
    }
    const uint8_t literal[] = {2,4};
    const uint8_t dictionary[] = {0,3};
    CHECK(libronx_explode(literal, 2, buffer, 64, &written) == -1);
    CHECK(libronx_explode(dictionary, 2, buffer, 64, &written) == -2);
    CHECK(libronx_explode(NULL, 0, NULL, 0, &written) == 2 && written == 0);
    CHECK(libronx_explode(dcl, sizeof(dcl), NULL, 0, &written) == 1);
    CHECK(written == 0);
    CHECK(libronx_explode(NULL, 1, buffer, 64, &written) ==
          LIBRONX_EXPLODE_INVALID_ARGUMENT && written == 0);
    CHECK(libronx_explode(dcl, sizeof(dcl), NULL, 1, &written) ==
          LIBRONX_EXPLODE_INVALID_ARGUMENT && written == 0);
    CHECK(libronx_explode(dcl, sizeof(dcl), buffer, 64, NULL) ==
          LIBRONX_EXPLODE_INVALID_ARGUMENT);

    memcpy(buffer + 16, dcl, sizeof(dcl));
    CHECK(libronx_explode(buffer + 16, sizeof(dcl), buffer + 16, 13,
                          &written) == LIBRONX_EXPLODE_INVALID_ARGUMENT);
    CHECK(libronx_explode(buffer + 16, sizeof(dcl), buffer + 17, 13,
                          &written) == LIBRONX_EXPLODE_INVALID_ARGUMENT);
    CHECK(libronx_explode(buffer + 16, sizeof(dcl), buffer + 15, 13,
                          &written) == LIBRONX_EXPLODE_INVALID_ARGUMENT);
    CHECK(written == 0 && memcmp(buffer + 16, dcl, sizeof(dcl)) == 0);
}

static void check_exact_dcl(void) {
    uint8_t buffer[32], input[sizeof(dcl) + 2];
    size_t written = 999;
    memset(buffer, 0xa5, sizeof(buffer));
    CHECK(libronx_explode_exact(dcl, sizeof(dcl), buffer + 1, 13,
                                &written) == 0);
    CHECK(written == 13 && memcmp(buffer + 1, dcl_plain, 13) == 0);
    CHECK(buffer[0] == 0xa5 && buffer[14] == 0xa5);
    for (size_t length = 0; length < sizeof(dcl); length++) {
        CHECK(libronx_explode_exact(dcl, length, buffer + 1, 13,
                                    &written) != 0);
        CHECK(written <= 13 && buffer[0] == 0xa5 && buffer[14] == 0xa5);
    }
    memcpy(input, dcl, sizeof(dcl));
    input[sizeof(dcl)] = 0;
    input[sizeof(dcl) + 1] = 0xa5;
    for (size_t length = sizeof(dcl) + 1; length <= sizeof(input); length++) {
        CHECK(libronx_explode_exact(input, length, buffer + 1, 13,
                                    &written) == LIBRONX_COMPRESSION_TRAILING_DATA);
        CHECK(written == 13 && buffer[0] == 0xa5 && buffer[14] == 0xa5);
        CHECK(libronx_explode(input, length, buffer + 1, 13,
                              &written) == 0);
    }
    CHECK(libronx_explode_exact(dcl, sizeof(dcl), buffer + 1, 12,
                                &written) == 1);
    CHECK(written <= 12 && buffer[0] == 0xa5 && buffer[14] == 0xa5);
    CHECK(libronx_explode_exact(NULL, 1, buffer, sizeof(buffer),
                                &written) == LIBRONX_EXPLODE_INVALID_ARGUMENT);
    CHECK(written == 0);
    CHECK(libronx_explode_exact(dcl, sizeof(dcl), buffer, sizeof(buffer),
                                NULL) == LIBRONX_EXPLODE_INVALID_ARGUMENT);
    memcpy(buffer, dcl, sizeof(dcl));
    CHECK(libronx_explode_exact(buffer, sizeof(dcl), buffer + 1, 13,
                                &written) == LIBRONX_EXPLODE_INVALID_ARGUMENT);
    CHECK(written == 0 && memcmp(buffer, dcl, sizeof(dcl)) == 0);
}

static void check_zlib(void) {
    uint8_t buffer[128], input[sizeof(zlib_stream) + 1];
    size_t written;
    memset(buffer, 0xa5, sizeof(buffer));
    CHECK(libronx_inflate_zlib(zlib_stream, sizeof(zlib_stream), buffer + 1,
                               sizeof(zlib_plain), &written) == 0);
    CHECK(written == sizeof(zlib_plain));
    CHECK(memcmp(buffer + 1, zlib_plain, sizeof(zlib_plain)) == 0);
    CHECK(buffer[0] == 0xa5 && buffer[sizeof(zlib_plain) + 1] == 0xa5);

    memset(buffer, 0xa5, sizeof(buffer));
    CHECK(libronx_inflate_zlib(zlib_stream, sizeof(zlib_stream), buffer + 1,
                               sizeof(zlib_plain) - 1, &written) != 0);
    CHECK(written <= sizeof(zlib_plain) - 1);
    CHECK(buffer[0] == 0xa5 && buffer[sizeof(zlib_plain)] == 0xa5);
    for (size_t length = 1; length < sizeof(zlib_stream); length++) {
        CHECK(libronx_inflate_zlib(zlib_stream, length, buffer, sizeof(buffer),
                                   &written) != 0);
        CHECK(written <= sizeof(buffer));
    }

    memcpy(input, zlib_stream, sizeof(zlib_stream));
    input[sizeof(zlib_stream)] = 0xa5;
    CHECK(libronx_inflate_zlib(input, sizeof(input), buffer, sizeof(buffer),
                               &written) == LIBRONX_COMPRESSION_TRAILING_DATA);
    input[sizeof(zlib_stream) - 1] ^= 1;
    CHECK(libronx_inflate_zlib(input, sizeof(zlib_stream), buffer, sizeof(buffer),
                               &written) != 0);
    CHECK(libronx_inflate_zlib(NULL, 0, buffer, 128, &written) ==
          LIBRONX_EXPLODE_INVALID_ARGUMENT && written == 0);
    CHECK(libronx_inflate_zlib(zlib_stream, sizeof(zlib_stream), NULL, 0,
                               &written) == LIBRONX_EXPLODE_INVALID_ARGUMENT);
    CHECK(written == 0);
    CHECK(libronx_inflate_zlib(zlib_stream, sizeof(zlib_stream), buffer, 128,
                               NULL) == LIBRONX_EXPLODE_INVALID_ARGUMENT);
    memcpy(buffer, zlib_stream, sizeof(zlib_stream));
    CHECK(libronx_inflate_zlib(buffer, sizeof(zlib_stream), buffer + 1, 55,
                               &written) == LIBRONX_EXPLODE_INVALID_ARGUMENT);
    CHECK(libronx_inflate_zlib(buffer + 1, sizeof(zlib_stream), buffer, 55,
                               &written) == LIBRONX_EXPLODE_INVALID_ARGUMENT);
    CHECK(written == 0 && memcmp(buffer, zlib_stream, sizeof(zlib_stream)) == 0);
#if SIZE_MAX > UINT_MAX
    CHECK(libronx_inflate_zlib(zlib_stream, (size_t)UINT_MAX + 1, buffer, 128,
                               &written) == LIBRONX_EXPLODE_INVALID_ARGUMENT);
    CHECK(libronx_inflate_zlib(zlib_stream, sizeof(zlib_stream), buffer,
                               (size_t)UINT_MAX + 1, &written) ==
          LIBRONX_EXPLODE_INVALID_ARGUMENT);
    CHECK(written == 0);
#endif
}

int main(void) {
    check_parallel_first_calls();
    check_dcl();
    check_exact_dcl();
    check_zlib();
#if defined(_WIN32)
    const char *platform = "windows";
#else
    const char *platform = "posix";
#endif
#if defined(__aarch64__) || defined(_M_ARM64)
    const char *architecture = "arm64";
#elif defined(__x86_64__) || defined(_M_X64)
    const char *architecture = "x86_64";
#else
    const char *architecture = "other";
#endif
    printf("{\"suite\":\"compression-contract\",\"platform\":\"%s\","
           "\"architecture\":\"%s\",\"assertions\":%u,\"failures\":%u,"
           "\"parallelWorkers\":%u,\"parallelDecodeCalls\":%u}\n",
           platform, architecture, assertions, failures, THREAD_COUNT,
           THREAD_COUNT * DECODES_PER_THREAD * 2);
    return failures == 0 ? 0 : 1;
}
