#include "CPUPowerPolicy.hpp"
#include "CoreCounters.hpp"
#include "CoreCounterCache.hpp"
#include <assert.h>
#include <stdio.h>

int main() {
    CoreCounters::Snapshot snapshot {};
    assert(sizeof(snapshot) == 96);
    assert(CoreCounters::version == 4);
    assert(CoreCounters::capacity == 1);
    assert(CoreCounters::acceptsInlineOutput(false, &snapshot, sizeof(snapshot)));
    assert(!CoreCounters::acceptsInlineOutput(true, &snapshot, sizeof(snapshot)));
    assert(!CoreCounters::acceptsInlineOutput(true, &snapshot, 8224));
    assert(!CoreCounters::acceptsInlineOutput(false, nullptr, sizeof(snapshot)));
    assert(!CoreCounters::acceptsInlineOutput(false, &snapshot, sizeof(snapshot) - 1));
    CoreCounters::Cache cache {};
    snapshot.version = 4;
    snapshot.count = 1;
    snapshot.logicalCPUPlusOne = 28;
    snapshot.cores[0] = {1, 42, 0x20, 1000000000, 1000000000, 100, 100, 2600000000};
    assert(cache.publish(27, snapshot));
    assert(!cache.publish(26, snapshot));
    assert(!cache.publish(256, snapshot));
    assert(cache.read(27, 1000000000).cores[0].valid == 1);
    assert(cache.read(27, 3000000000).cores[0].valid == 1);
    assert(cache.read(27, 3000000001).cores[0].valid == 0);
    assert(cache.read(27, 999999999).cores[0].valid == 0);
    assert(cache.read(28, 1000000000).cores[0].valid == 0);
    assert(cache.read(256, 1000000000).cores[0].valid == 0);
    cache.clear();
    assert(cache.read(27, 1000000000).cores[0].valid == 0);
    using namespace CPUPowerPolicy;
    const uint64_t original = (250ULL << 32) | 250 | (1ULL << 15) | (1ULL << 47);
    uint64_t targetValue = 0;
    for (unsigned mode = 0; mode < 5; ++mode) {
        assert(target(original, original, 0, mode, &targetValue));
        assert((targetValue & 0x7FFF) == watts[mode][0]);
        assert(((targetValue >> 32) & 0x7FFF) == watts[mode][1]);
        assert((targetValue & ~mask) == (original & ~mask));
        assert(restoreOwnedPackage(true, original, targetValue, targetValue) == original);
    }
    const uint64_t external = (75ULL << 32) | 50 | (original & ~mask);
    assert(restoreOwnedPackage(true, original, external, targetValue) == external);
    assert(restoreOwnedPackage(false, original, targetValue, targetValue) == targetValue);
    const uint64_t changedTau = targetValue ^ (1ULL << 17);
    assert(restoreOwnedPackage(true, original, changedTau, targetValue) ==
           (original ^ (1ULL << 17)));
    assert(restoreOwnedByte(true, 0xC1, 0xC4, 0xC4) == 0xC1);
    assert(restoreOwnedByte(true, 0xC1, 0xC2, 0xC4) == 0xC2);
    assert(restoreOwnedByte(false, 0x0D, 0x1D, 0x1D) == 0x1D);
    assert(restoreOwnedByte(true, 0x0D, 0x1D, 0x1D) == 0x0D);
    puts("Power policy regression checks passed.");
}
