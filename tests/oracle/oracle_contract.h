#ifndef ZLAY_TESTS_ORACLE_CONTRACT_H
#define ZLAY_TESTS_ORACLE_CONTRACT_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

_Static_assert(sizeof(float) == sizeof(uint32_t), "oracle contracts require 32-bit float");

static uint32_t oracle_f32_bits(float value) {
    uint32_t bits = 0;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static void oracle_fail_on_error(Clay_ErrorData error) {
    fprintf(stderr,
            "unexpected oracle diagnostic %d: %.*s\n",
            (int)error.errorType,
            (int)error.errorText.length,
            error.errorText.chars);
    fflush(stderr);
    exit(3);
}

static void oracle_fail_log_overflow(const char *name) {
    fprintf(stderr, "oracle log overflow: %s\n", name);
    fflush(stderr);
    exit(4);
}

#endif
