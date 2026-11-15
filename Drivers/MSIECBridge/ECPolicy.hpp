#ifndef MSIEC_POLICY_HPP
#define MSIEC_POLICY_HPP

#include <stdint.h>

namespace MSIECPolicy {
constexpr uint32_t apiVersion = 9;
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
    const char known[] = "15P2EMS1.110";
    bool match = true;
    for (uint32_t index = 0; index < firmwareLength; ++index)
        if (bytes[index] != static_cast<uint8_t>(known[index])) match = false;
    return match || supportsFirmware(bytes);
}

inline bool validPercent(uint64_t value) { return value >= 10 && value <= 100; }
inline uint8_t encode(uint8_t percent) { return static_cast<uint8_t>(percent | 0x80); }
inline bool validCurrent(uint64_t value) {
    return value <= 255 && (value == 0x80 || validPercent(value & 0x7F));
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
