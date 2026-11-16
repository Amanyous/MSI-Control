#include "IntelFrequency.hpp"
#include <assert.h>
#include <map>
#include <stdio.h>
#include <vector>

struct CPU {
    std::map<uint32_t, IntelFrequency::Registers> leaves;
    std::map<uint32_t, uint64_t> msrs;
    std::vector<uint32_t> reads;
    uint64_t time {1000000000};
    CPU(uint32_t model, uint32_t maximum, uint32_t baseMHz = 0) {
        leaves[0] = {maximum, 0x756e6547, 0x6c65746e, 0x49656e69};
        leaves[1] = {0x600U | ((model & 15) << 4) | ((model & 0xF0) << 12),
                     (2U << 16) | (6U << 24), 0, 0};
        leaves[6].c = 1;
        leaves[0xB] = {0, 2, 0, 6};
        leaves[0x16].a = baseMHz;
        msrs[0xCE] = 26U << 8;
        msrs[0xE8] = 1950000000;
        msrs[0xE7] = 1300000000;
    }
    bool collect(CoreCounters::Record &record) {
        const auto maximum = leaves[0].a;
        return IntelFrequency::collect(record, [&](uint32_t leaf, uint32_t sub) {
            assert(sub == 0 && leaf <= maximum);
            return leaves[leaf];
        }, [&](uint32_t address, uint64_t &value) {
            reads.push_back(address);
            const auto found = msrs.find(address);
            if (found == msrs.end()) return false;
            value = found->second;
            return true;
        }, [&] { return time; });
    }
};

int main() {
    CoreCounters::Record record {};
    for (auto model : {0x2A, 0x3A, 0x3C, 0x45, 0x46, 0x3D, 0x47,
                       0x4E, 0x5E, 0x8E, 0x9E, 0xA5, 0xA6, 0x7D, 0x7E, 0x8C, 0x8D, 0xA7}) {
        CPU cpu(model, 0xD);
        assert(cpu.collect(record));
        assert(record.valid == 1 && record.type == 0 && record.apic == 6);
        assert(record.baseHz == 2600000000 && record.tscHz == 1000000000);
        assert(record.tsc == cpu.time && record.aperf == 1950000000);
        assert((cpu.reads == std::vector<uint32_t>{0xCE, 0xE8, 0xE7}));
    }
    CPU skylake(0x5E, 0x16, 2800);
    assert(skylake.collect(record) && record.baseHz == 2800000000);
    assert((skylake.reads == std::vector<uint32_t>{0xE8, 0xE7}));
    CPU zeroBase(0x5E, 0x16);
    assert(zeroBase.collect(record) && record.baseHz == 2600000000);
    CPU legacyAPIC(0x2A, 6);
    assert(legacyAPIC.collect(record) && record.apic == 6);
    CPU missingTopology(0x2A, 0xD);
    missingTopology.leaves[0xB].b = 0;
    assert(missingTopology.collect(record) && record.apic == 6);
    for (auto type : {0x20U, 0x40U}) {
        CPU hybrid(0xB7, 0x1A, 2100);
        hybrid.leaves[7].d = 1U << 15;
        hybrid.leaves[0x1A].a = type << 24;
        assert(hybrid.collect(record) && record.type == type);
        assert(hybrid.reads.size() == 2);
    }
    for (unsigned failure = 0; failure < 15; ++failure) {
        CPU cpu(0x3C, 0xD);
        switch (failure) {
            case 0: cpu.leaves[0].b = 0; break;
            case 1: cpu.leaves[0].a = 5; break;
            case 2: cpu.leaves[1].a = 0xF00; break;
            case 3: cpu.leaves[6].c = 0; break;
            case 4: cpu.leaves[1].a = 0x30670; break; // Unknown model, no clock fallback.
            case 5: cpu.msrs.erase(0xCE); break;
            case 6: cpu.msrs[0xCE] = 0; break;
            case 7: cpu.msrs[0xCE] = 101U << 8; break;
            case 8: cpu.msrs.erase(0xE8); break;
            case 9: cpu.msrs.erase(0xE7); break;
            case 10: cpu.time = 0; break;
            case 11: cpu.leaves[7].d = 1U << 15; break; // Hybrid without leaf 1A.
            case 12:
                cpu.leaves[0].a = 0x1A;
                cpu.leaves[7].d = 1U << 15;
                cpu.leaves[0x1A].a = 0x10U << 24;
                break;
            case 13:
                cpu.leaves[0].a = 0x16;
                cpu.leaves[0x16].a = 10001;
                break;
            case 14:
                cpu.leaves[0xB].b = 0;
                cpu.leaves[1].b = 0;
                break;
        }
        record = {};
        assert(!cpu.collect(record));
        assert(record.valid == 0);
        if (failure <= 4 || failure >= 11) assert(cpu.reads.empty());
    }
    puts("Intel frequency capability and legacy clock checks passed.");
}
