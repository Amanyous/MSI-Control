#pragma once
#include <stdint.h>

namespace CoreCounters {
constexpr unsigned capacity = 1;
constexpr uint64_t version = 4;
struct Record {
    // Protocol 3 uses monotonic nanoseconds in tsc and 1 GHz in tscHz.
    uint64_t valid, apic, type, tscHz, tsc, aperf, mperf, baseHz;
};
struct Snapshot {
    // Protocol 4 replaces the reserved word with the local OS CPU number plus one.
    uint64_t version, count, overflow, logicalCPUPlusOne;
    Record cores[capacity];
};
static_assert(sizeof(Snapshot) == 96, "Counter response must remain inline.");
inline bool acceptsInlineOutput(bool descriptor, const void *output, uint64_t size) {
    return !descriptor && output && size >= sizeof(Snapshot);
}
}
