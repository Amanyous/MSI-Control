#pragma once
#include <mach/mach_types.h>
#include <stddef.h>

// ABI subset from Apple XNU i386/pmCPU.h and cpu_topology.h (APSL 2.0).
// Only Darwin 25.6 is enabled, verified against this machine's kernel.
namespace ProcessorBinding {
struct LogicalCPU {
    void *links[8];
    uint32_t flags, number, logical, physical;
    boolean_t master, primary;
    volatile uint32_t state;
    volatile boolean_t stopped;
};
struct Callbacks {
    void *prefix[3];
    LogicalCPU *(*logicalCPU)(int);
    void *middle[10];
    processor_t (*processor)(int);
    processor_t (*bind)(processor_t);
    void *suffix[11];
};
static_assert(offsetof(Callbacks, processor) == 0x70, "PM callback ABI");
static_assert(sizeof(Callbacks) == 0xD8, "PM callback size");
static_assert(offsetof(LogicalCPU, state) == 88, "LCPU ABI");
inline bool supportedKernel(int major, int minor) { return major == 25 && minor == 6; }
inline bool schedulable(const LogicalCPU *cpu, unsigned index) {
    return cpu && cpu->number == index && !cpu->stopped &&
        (cpu->state == 4 || cpu->state == 5);
}
}
extern "C" void pmKextRegister(uint32_t, void *, ProcessorBinding::Callbacks *);
extern "C" const int version_major;
extern "C" const int version_minor;
