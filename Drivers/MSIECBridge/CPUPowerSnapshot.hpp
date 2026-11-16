#pragma once
#include <stdint.h>

namespace CPUPowerSnapshot {
constexpr unsigned count = 16;
constexpr uint64_t version = 1;
inline bool supportsPackagePower(uint32_t family, uint32_t model) {
    return family == 6 && (model == 0xB7 || model == 0xBF);
}
// ABI: version, validity, vendor leaf EBX/EDX/ECX, max basic leaf,
// signature, leaf6 EAX, sample x2APIC ID, PM_ENABLE, HWP_CAPABILITIES,
// HWP_REQUEST, RAPL_UNIT, PKG_POWER_LIMIT, max extended leaf, reserved.
}
