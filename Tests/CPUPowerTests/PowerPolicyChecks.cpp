#include "../../Drivers/MSIECBridge/CPUPowerPolicy.hpp"
#include <assert.h>

int main() {
    using namespace CPUPowerPolicy;
    const uint64_t original = 0x004287d000df87d0ULL;
    uint64_t result = 0;
    for (unsigned mode = 0; mode < 5; ++mode) {
        assert(target(original, original, 3, mode, &result));
        assert((result & ~mask) == (original & ~mask));
        assert((result & 0x7FFF) == watts[mode][0] * 8);
        assert(((result >> 32) & 0x7FFF) == watts[mode][1] * 8);
        assert(restored(original, result) == original);
        assert(owns(result, result));
        assert(!owns(result ^ 1, result));
    }
    assert(!target(original, original, 3, 5, &result));
    assert(!target(original | (1ULL << 63), original, 3, 0, &result));
    assert(!target(original, original & ~(1ULL << 15), 3, 0, &result));
    const uint64_t small = (original & ~mask) | 80 | (80ULL << 32);
    assert(!target(small, small, 3, 0, &result));
    assert(!target(original, original, 15, 4, &result));
    const uint64_t unrelated = original ^ (1ULL << 16);
    assert(owns(unrelated, original));
    assert((restored(original, unrelated) & ~mask) == (unrelated & ~mask));
}
