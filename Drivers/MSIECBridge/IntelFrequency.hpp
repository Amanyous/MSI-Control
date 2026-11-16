#pragma once
#include "CoreCounters.hpp"

namespace IntelFrequency {
struct Registers { uint32_t a, b, c, d; };

inline bool has100MHzPlatformRatio(uint32_t model) {
    switch (model) {
        case 0x2A: case 0x3A:                         // Sandy / Ivy Bridge client
        case 0x3C: case 0x45: case 0x46:              // Haswell client
        case 0x3D: case 0x47:                         // Broadwell client
        case 0x4E: case 0x5E: case 0x8E: case 0x9E:   // Skylake / Kaby Lake
        case 0xA5: case 0xA6:                         // Comet Lake
        case 0x7D: case 0x7E:                         // Ice Lake client
        case 0x8C: case 0x8D: case 0xA7:              // Tiger / Rocket Lake
            return true;
        default: return false;
    }
}

// Callbacks keep the capability and clock decisions identical in kernel and host tests.
template<class CPUID, class ReadMSR, class ReadTime>
bool collect(CoreCounters::Record &record, CPUID cpuid, ReadMSR readMSR, ReadTime readTime) {
    const auto vendor = cpuid(0, 0);
    if (vendor.a < 6 || vendor.b != 0x756e6547 ||
        vendor.d != 0x49656e69 || vendor.c != 0x6c65746e) return false;
    const auto identity = cpuid(1, 0);
    if (((identity.a >> 8) & 15) != 6 || (identity.a & (0xFFU << 20))) return false;
    const auto model = ((identity.a >> 4) & 15) | ((identity.a >> 12) & 0xF0);
    if (!(cpuid(6, 0).c & 1)) return false;
    uint64_t apic = (identity.b >> 24) & 0xFF;
    if (vendor.a >= 0xB) {
        const auto topology = cpuid(0xB, 0);
        if (topology.b != 0) apic = topology.d;
        else if (((identity.b >> 16) & 0xFF) == 0) return false;
    } else if (((identity.b >> 16) & 0xFF) == 0) return false;
    const bool hybrid = vendor.a >= 7 && (cpuid(7, 0).d & (1U << 15));
    uint64_t type = 0;
    if (hybrid) {
        if (vendor.a < 0x1A) return false;
        type = cpuid(0x1A, 0).a >> 24;
        if (type != 0x20 && type != 0x40) return false;
    }
    uint64_t baseHz = 0;
    if (vendor.a >= 0x16) baseHz = uint64_t(cpuid(0x16, 0).a & 0xFFFF) * 1000000;
    if (baseHz == 0 && !hybrid && has100MHzPlatformRatio(model)) {
        uint64_t info = 0;
        if (!readMSR(0xCE, info)) return false;
        const auto ratio = (info >> 8) & 0xFF;
        if (ratio == 0 || ratio > 100) return false;
        baseHz = ratio * 100000000;
    }
    if (baseHz < 100000000 || baseHz > 10000000000ULL) return false;
    uint64_t aperf = 0, mperf = 0;
    if (!readMSR(0xE8, aperf) || !readMSR(0xE7, mperf)) return false;
    const auto nanoseconds = readTime();
    if (nanoseconds == 0) return false;
    record = {1, apic, type, 1000000000, nanoseconds, aperf, mperf, baseHz};
    return true;
}
}
