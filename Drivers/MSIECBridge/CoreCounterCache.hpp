#pragma once
#include "CoreCounters.hpp"

namespace CoreCounters {
constexpr unsigned cacheCapacity = 256;
constexpr uint64_t cacheVersion = 1;
constexpr uint64_t cacheLifetime = 2000000000ULL;

// Caller serializes access. No allocation or hardware access in the cache.
struct Cache {
    Snapshot slots[cacheCapacity] {};
    void clear() {
        for (auto &slot : slots) slot = {};
    }
    bool publish(unsigned index, const Snapshot &snapshot) {
        if (index >= cacheCapacity || snapshot.version != version ||
            snapshot.count != 1 || snapshot.logicalCPUPlusOne != index + 1 ||
            snapshot.cores[0].valid != 1) return false;
        slots[index] = snapshot;
        return true;
    }
    Snapshot read(unsigned index, uint64_t now, uint64_t generation = 0) const {
        Snapshot missing {};
        missing.version = version;
        missing.count = 1;
        missing.logicalCPUPlusOne = index + 1;
        if (index >= cacheCapacity) return missing;
        const auto &slot = slots[index];
        const auto time = slot.cores[0].tsc;
        auto result = time && now >= time && now - time <= cacheLifetime ? slot : missing;
        result.overflow = generation; // Cache-only header: lifecycle generation, not local protocol overflow.
        return result;
    }
};
}
