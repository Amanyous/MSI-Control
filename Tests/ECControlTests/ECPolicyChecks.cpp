#include "../../Drivers/MSIECBridge/ECPolicy.hpp"
#include <cassert>
#include <cstdio>
#include <cstring>
#include <initializer_list>

int main() {
    for (unsigned byte = 0; byte < 256; ++byte) {
        for (unsigned state = 0; state < 2; ++state) {
            const auto value = MSIECPolicy::muteLEDValue(byte, state);
            assert((value & ~0x02) == (byte & ~0x02));
            assert(bool(value & 0x02) == bool(state));
        }
    }
    assert(MSIECPolicy::muteLEDAddress(0) == 0x2D);
    assert(MSIECPolicy::muteLEDAddress(1) == 0x2C);
    assert(MSIECPolicy::validMuteLED(0, 1) && MSIECPolicy::validMuteLED(1, 0));
    assert(!MSIECPolicy::validMuteLED(2, 0) && !MSIECPolicy::validMuteLED(0, 2));
    for (unsigned value = 0; value <= 512; ++value) {
        assert(MSIECPolicy::validPercent(value) == (value >= 10 && value <= 100));
        assert(MSIECPolicy::validCurrent(value) == (value <= 255 && (value & 0x80) && (value == 0x80 ||
               ((value & 0x7F) >= 10 && (value & 0x7F) <= 100))));
        if (MSIECPolicy::validPercent(value)) assert(MSIECPolicy::encode(value) == (value | 0x80));
    }
    assert(MSIECPolicy::encode(60) == 0xBC);
    assert(MSIECPolicy::encode(80) == 0xD0);
    assert(MSIECPolicy::encode(100) == 0xE4);
    for (const char *known : {"15P4EMS1.105", "15P4EMS1.107"}) {
        uint8_t firmware[MSIECPolicy::firmwareLength];
        std::memcpy(firmware, known, sizeof(firmware));
        assert(MSIECPolicy::supportsFirmware(firmware));
        for (unsigned position = 0; position < sizeof(firmware); ++position) {
            for (unsigned other = 0; other <= 255; ++other) {
                uint8_t changed[sizeof(firmware)];
                std::memcpy(changed, firmware, sizeof(firmware));
                changed[position] = other;
                const bool isKnown = !std::memcmp(changed, "15P4EMS1.105", sizeof(firmware)) ||
                                     !std::memcmp(changed, "15P4EMS1.107", sizeof(firmware));
                assert(MSIECPolicy::supportsFirmware(changed) == isKnown);
            }
        }
    }
    uint8_t fanFirmware[MSIECPolicy::firmwareLength];
    std::memcpy(fanFirmware, "15P2EMS1.110", sizeof(fanFirmware));
    assert(MSIECPolicy::supportsFan(fanFirmware));
    assert(!MSIECPolicy::supportsFirmware(fanFirmware));
    assert(MSIECPolicy::supportsCharge(fanFirmware));
    fanFirmware[11] = '1';
    assert(!MSIECPolicy::supportsFan(fanFirmware));
    assert(MSIECPolicy::supportsCharge(fanFirmware));
    for (const auto &profile : MSIECProfiles::profiles) {
        uint8_t firmware[12];
        std::memcpy(firmware, profile.family, 10);
        firmware[10] = '9'; firmware[11] = '9';
        assert(MSIECProfiles::match(firmware) == &profile);
        assert(MSIECPolicy::supportsCharge(firmware) == (profile.chargeAddress != 0));
        assert(profile.fanAddress == 0xD4 || profile.fanAddress == 0xF4);
        for (unsigned byte = 0; byte < 256; ++byte) {
            for (unsigned enabled = 0; enabled < 2; ++enabled) {
                uint8_t target = 0;
                assert(MSIECPolicy::commonTarget(profile, 1, enabled, byte, &target));
                const unsigned mask = 1U << profile.fnWinBit;
                assert((target & ~mask) == (byte & ~mask));
                assert((bool(target & mask) != profile.fnWinInverted) == bool(enabled));
                const bool webcam = MSIECPolicy::commonTarget(profile, 0, enabled, byte, &target);
                assert(webcam == (profile.webcamAddress <= 255));
                if (webcam) {
                    const unsigned cameraMask = 1U << profile.webcamBit;
                    assert((target & ~cameraMask) == (byte & ~cameraMask));
                    assert(bool(target & cameraMask) == bool(enabled));
                }
            }
        }
        uint8_t target = 0;
        assert(!MSIECPolicy::commonTarget(profile, 4, 0, 0, &target));
        assert(!MSIECPolicy::commonTarget(profile, 1, 2, 0, &target));
        assert(!MSIECPolicy::commonTarget(profile, 2, 0xFF, 0xC1, &target));
        for (unsigned i = 0; i < profile.shiftCount; ++i)
            assert(MSIECPolicy::commonTarget(profile, 2, profile.shiftModes[i], profile.shiftModes[0], &target));
        for (unsigned i = 0; i < profile.modeCount; ++i)
            assert(MSIECPolicy::commonTarget(profile, 3, profile.modes[i], profile.modes[0], &target));
        firmware[0] = '?';
        assert(MSIECProfiles::match(firmware) == nullptr);
    }
    assert(MSIECPolicy::validShiftMode(0xC1) && MSIECPolicy::validShiftMode(0xC4));
    assert(!MSIECPolicy::validShiftMode(0xC2));
    const uint8_t temperatures[] = {0, 50, 57, 64, 70, 76};
    assert(MSIECPolicy::validCurveTemperatures(temperatures));
    const uint8_t descending[] = {0, 50, 57, 56, 70, 76};
    assert(!MSIECPolicy::validCurveTemperatures(descending));
    assert(MSIECPolicy::validCurveSpeed(0) && !MSIECPolicy::validDesiredCurveSpeed(0));
    assert(MSIECPolicy::validDesiredCurveSpeed(20) && MSIECPolicy::validDesiredCurveSpeed(150));
    assert(!MSIECPolicy::validDesiredCurveSpeed(151));
    std::puts("PASS kernel policy: percent/byte bounds and all single-byte firmware mutations; no hardware accessed.");
}
