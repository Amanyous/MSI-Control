#ifndef MSIEC_POLICY_HPP
#define MSIEC_POLICY_HPP

#include <stdint.h>
#include "ECProfiles.hpp"

namespace MSIECPolicy {
constexpr uint32_t apiVersion = 15;
constexpr uint8_t muteLEDBit = 0x02;
inline bool validMuteLED(uint64_t led, uint64_t enabled) { return led <= 1 && enabled <= 1; }
inline uint8_t muteLEDAddress(uint64_t led) { return led == 0 ? 0x2D : 0x2C; }
inline uint8_t muteLEDValue(uint8_t current, bool enabled) {
    return static_cast<uint8_t>((current & ~muteLEDBit) | (enabled ? muteLEDBit : 0));
}
constexpr uint32_t firmwareLength = 12;
constexpr uint8_t firmwareAddress = 0xA0;
constexpr uint8_t chargeAddress = 0xD7;
constexpr uint8_t fanModeAddress = 0xD4;
constexpr uint8_t shiftModeAddress = 0xD2;
constexpr uint8_t coolerBoostAddress = 0x98;
constexpr uint8_t coolerBoostBit = 0x80;
constexpr uint8_t curveCpuTemperature = 0x69;
constexpr uint8_t curveCpuSpeed = 0x72;
constexpr uint8_t curveGpuTemperature = 0x81;
constexpr uint8_t curveGpuSpeed = 0x8A;
constexpr uint32_t curvePoints = 6;
enum Selector : uint32_t { firmware = 0, readByte = 1, setChargeLimit = 2, setFanMode = 3, setCoolerBoost = 4, setFanCurve = 5, setPerformance = 6 };

inline bool supportsFirmware(const uint8_t *bytes) {
    const char *known[] = {"15P4EMS1.105", "15P4EMS1.107"};
    for (const char *candidate : known) {
        bool equal = true;
        for (uint32_t index = 0; index < firmwareLength; ++index) {
            if (bytes[index] != static_cast<uint8_t>(candidate[index])) equal = false;
        }
        if (equal) return true;
    }
    return false;
}
inline bool supportsCharge(const uint8_t *bytes) {
    const auto *profile = MSIECProfiles::match(bytes);
    return profile && profile->chargeAddress != 0;
}

inline bool validPercent(uint64_t value) { return value >= 10 && value <= 100; }
inline uint8_t encode(uint8_t percent) { return static_cast<uint8_t>(percent | 0x80); }
inline bool validCurrent(uint64_t value) {
    return value <= 255 && (value & 0x80) && (value == 0x80 || validPercent(value & 0x7F));
}
inline bool commonTarget(const MSIECProfiles::Profile &profile, uint64_t feature,
                         uint64_t desired, uint64_t current, uint8_t *target) {
    if (desired > 255 || current > 255) return false;
    if (feature <= 1) {
        const auto address = feature == 0 ? profile.webcamAddress : profile.fnWinAddress;
        const uint8_t bit = feature == 0 ? profile.webcamBit : profile.fnWinBit;
        if (address > 255 || bit > 7 || desired > 1) return false;
        const uint8_t mask = static_cast<uint8_t>(1U << bit);
        const bool set = (desired == 1) != (feature == 1 && profile.fnWinInverted);
        *target = static_cast<uint8_t>((current & static_cast<uint8_t>(~mask)) | (set ? mask : 0));
        return true;
    }
    if (feature > 3 || (feature == 2 && profile.shiftAddress > 255)) return false;
    const uint8_t *modes = feature == 2 ? profile.shiftModes : profile.modes;
    const unsigned count = feature == 2 ? profile.shiftCount : profile.modeCount;
    bool desiredValid = false, currentValid = false;
    for (unsigned i = 0; i < count; ++i) {
        desiredValid |= desired == modes[i];
        currentValid |= current == modes[i];
    }
    *target = static_cast<uint8_t>(desired);
    return desiredValid && currentValid;
}
inline bool validFanMode(uint64_t value) { return value == 0x0D || value == 0x1D || value == 0x8D; }
inline bool validShiftMode(uint64_t value) { return value == 0xC1 || value == 0xC4; }
inline bool supportsFan(const uint8_t *bytes) {
    const char known[] = "15P2EMS1.110";
    for (uint32_t index = 0; index < firmwareLength; ++index)
        if (bytes[index] != static_cast<uint8_t>(known[index])) return false;
    return true;
}
inline bool validCurveSpeed(uint64_t value) { return value <= 150; }
inline bool validDesiredCurveSpeed(uint64_t value) { return value >= 20 && value <= 150; }
inline bool validCurveTemperature(uint64_t value) { return value <= 110; }
inline bool validCurveTemperatures(const uint8_t *values) {
    for (uint32_t i = 0; i < curvePoints; ++i)
        if (!validCurveTemperature(values[i]) || (i && values[i-1] > values[i])) return false;
    return true;
}
}
#endif
