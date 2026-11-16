#pragma once
#include <stdint.h>

namespace CPUPowerPolicy {
constexpr uint64_t mask = 0x7FFFULL | (0x7FFFULL << 32);
constexpr unsigned statusCount = 14;
constexpr uint64_t watts[5][2] = {{25,35}, {35,55}, {45,65}, {55,80}, {65,90}};
inline bool validBaseline(uint64_t value) {
    return !(value >> 63) && (value & (1ULL << 15)) &&
        (value & (1ULL << 47)) && (value & 0x7FFF) &&
        ((value >> 32) & 0x7FFF);
}
inline bool target(uint64_t original, uint64_t current, uint64_t unit,
                   unsigned mode, uint64_t *result) {
    if (mode >= 5 || !validBaseline(original) || !validBaseline(current)) return false;
    const unsigned exponent = unit & 15;
    const uint64_t pl1 = watts[mode][0] << exponent;
    const uint64_t pl2 = watts[mode][1] << exponent;
    if (pl1 > 0x7FFF || pl2 > 0x7FFF ||
        pl1 > (original & 0x7FFF) || pl2 > ((original >> 32) & 0x7FFF)) return false;
    *result = (current & ~mask) | pl1 | (pl2 << 32);
    return true;
}
inline uint64_t restored(uint64_t original, uint64_t current) {
    return (current & ~mask) | (original & mask);
}
inline bool owns(uint64_t current, uint64_t last) {
    return (current & mask) == (last & mask);
}
inline uint64_t restoreOwnedPackage(bool owned, uint64_t original, uint64_t current, uint64_t last) {
    return owned && owns(current, last) ? restored(original, current) : current;
}
inline uint8_t restoreOwnedByte(bool owned, uint8_t original, uint8_t current, uint8_t last) {
    return owned && current == last ? original : current;
}
}
