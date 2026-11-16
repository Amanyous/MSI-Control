#!/usr/bin/env python3
"""Generate factual register mappings from an explicitly supplied msi-ec source."""
import hashlib
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
source = Path(sys.argv[1]).read_bytes()
text = source.decode()
digest = hashlib.sha256(source).hexdigest()
rows = []
def block(conf, name):
    match = re.search(r"\." + name + r"\s*=\s*\{(.*?)\n\t\},", conf, re.S)
    if not match:
        raise ValueError("Missing block: " + name)
    return match[1]

def number(body, name):
    value = re.search(r"\." + name + r"\s*=\s*([^,]+)", body)[1].strip()
    if value in ("MSI_EC_ADDR_UNKNOWN", "MSI_EC_ADDR_UNSUPP"):
        return None
    return int(value, 0)

for name, body in re.findall(r"static const char \*ALLOWED_FW_(\w+)\[\].*?= \{(.*?)\};", text, re.S):
    match = re.search(r"static struct msi_ec_conf CONF_" + name + r"\b.*?= \{(.*?)^\};", text, re.S | re.M)
    if not match:
        raise ValueError(name)
    conf = match[1]
    charge = re.search(r"\.charge_control_address\s*=\s*([^,]+)", conf)[1].strip()
    fan = re.search(r"\.fan_mode\s*=\s*\{\s*\.address\s*=\s*(0x[0-9a-f]+)", conf)[1]
    fan_body = conf.split(".fan_mode =", 1)[1].split(".cpu =", 1)[0]
    modes = [int(value, 16) for value in re.findall(r"\{\s*FM_\w+_NAME,\s*(0x[0-9a-f]+)", fan_body)]
    boost = re.search(r"\.cooler_boost\s*=\s*\{\s*\.address\s*=\s*0x98,\s*\.bit\s*=\s*7,", conf)
    if not boost:
        raise ValueError("Unreviewed boost layout: " + name)
    address = int(charge, 16) if charge.startswith("0x") else None
    webcam, fn, shift = (block(conf, feature) for feature in ("webcam", "fn_win_swap", "shift_mode"))
    shift_modes = [(mode.lower(), int(value, 16)) for mode, value in
                   re.findall(r"\{\s*SM_(\w+)_NAME,\s*(0x[0-9a-f]+)", shift)]
    fan_names = [mode.lower() for mode in re.findall(r"\{\s*FM_(\w+)_NAME,", fan_body)]
    metadata = [
        number(webcam, "address"), number(webcam, "block_address"), number(webcam, "bit"),
        number(fn, "address"), number(fn, "bit"),
        re.search(r"\.invert\s*=\s*(true|false)", fn)[1] == "true",
        number(shift, "address"), shift_modes, fan_names,
        number(block(conf, "cpu"), "rt_temp_address"),
        number(block(conf, "gpu"), "rt_temp_address"),
        number(block(conf, "cpu"), "rt_fan_speed_address"),
        number(block(conf, "gpu"), "rt_fan_speed_address"),
    ]
    for firmware in re.findall(r'"([^"]+)"', body):
        if len(firmware) != 10:
            raise ValueError(firmware)
        per_family = list(metadata)
        # Upstream comments explicitly identify these families without webcam control.
        if firmware.startswith(("159K", "15H5", "13P5")):
            per_family[0] = per_family[1] = None
        rows.append((firmware, name, address, int(fan, 16), modes, per_family))
if len({row[0] for row in rows}) != len(rows):
    raise ValueError("Duplicate firmware family")
notice = (
    "// Generated factual firmware/register mappings; do not edit by hand.\n"
    "// Source: https://github.com/BeardOverflow/msi-ec/blob/master/msi-ec.c\n"
    "// Upstream license: GPL-2.0-or-later. No upstream implementation copied.\n"
    f"// Reviewed source SHA256: {digest}\n"
)
swift = notice + """
import Foundation

public struct ECFeatureProfile: Sendable {
    public let name: String
    public let chargeAddress: UInt8?
    public let fanAddress: UInt8
    public let fanModes: [UInt8]
    public let webcamAddress: UInt8?
    public let webcamBlockAddress: UInt8?
    public let webcamBit: UInt8
    public let fnWinAddress: UInt8?
    public let fnWinBit: UInt8
    public let fnWinInverted: Bool
    public let shiftAddress: UInt8?
    public let shiftModes: [ECNamedMode]
    public let namedFanModes: [ECNamedMode]
    public let cpuTemperatureAddress: UInt8?
    public let gpuTemperatureAddress: UInt8?
    public let cpuFanAddress: UInt8?
    public let gpuFanAddress: UInt8?
    public static func match(_ firmware: String) -> ECFeatureProfile? {
        guard firmware.utf8.count == 12,
              firmware.utf8.allSatisfy({ (0x20...0x7E).contains($0) }) else { return nil }
        return families[String(firmware.prefix(10))]
    }
    private static let families: [String: ECFeatureProfile] = [
"""
cpp = notice + """
#ifndef MSIEC_PROFILES_HPP
#define MSIEC_PROFILES_HPP
#include <stdint.h>
namespace MSIECProfiles {
struct Profile {
    const char *family;
    const char *name;
    uint8_t chargeAddress;
    uint8_t fanAddress;
    uint8_t modes[4];
    uint8_t modeCount;
    uint16_t webcamAddress, webcamBlockAddress;
    uint8_t webcamBit;
    uint16_t fnWinAddress;
    uint8_t fnWinBit;
    bool fnWinInverted;
    uint16_t shiftAddress;
    uint8_t shiftModes[4];
    uint8_t shiftCount;
};
constexpr Profile profiles[] = {
"""
for firmware, name, charge, fan, modes, metadata in rows:
    values = ", ".join(hex(value) for value in modes)
    cam, cam_block, cam_bit, fn, fn_bit, invert, shift, shift_modes, fan_names, cpu_temp, gpu_temp, cpu_fan, gpu_fan = metadata
    def sw(value):
        return hex(value) if value is not None else "nil"
    def cc(value):
        return hex(value) if value is not None else "0x100"
    named_shift = ", ".join(f'.init(name: "{mode}", value: {hex(value)})' for mode, value in shift_modes)
    named_fan = ", ".join(f'.init(name: "{mode}", value: {hex(value)})' for mode, value in zip(fan_names, modes))
    swift += (f'        "{firmware}": .init(name: "{name}", chargeAddress: {sw(charge)}, fanAddress: {hex(fan)}, fanModes: [{values}], '
              f'webcamAddress: {sw(cam)}, webcamBlockAddress: {sw(cam_block)}, webcamBit: {cam_bit}, '
              f'fnWinAddress: {sw(fn)}, fnWinBit: {fn_bit}, fnWinInverted: {str(invert).lower()}, '
              f'shiftAddress: {sw(shift)}, shiftModes: [{named_shift}], namedFanModes: [{named_fan}], '
              f'cpuTemperatureAddress: {sw(cpu_temp)}, gpuTemperatureAddress: {sw(gpu_temp)}, '
              f'cpuFanAddress: {sw(cpu_fan)}, gpuFanAddress: {sw(gpu_fan)}),\n')
    shift_values = ", ".join(hex(value) for _, value in shift_modes)
    cpp += (f'    {{"{firmware}", "{name}", {hex(charge or 0)}, {hex(fan)}, {{{values}}}, {len(modes)}, '
            f'{cc(cam)}, {cc(cam_block)}, {cam_bit}, {cc(fn)}, {fn_bit}, {str(invert).lower()}, '
            f'{cc(shift)}, {{{shift_values}}}, {len(shift_modes)}}},\n')
swift += "    ]\n}\n"
cpp += """};
inline const Profile *match(const uint8_t *firmware) {
    for (unsigned i = 0; i < 12; ++i)
        if (firmware[i] < 0x20 || firmware[i] > 0x7e) return nullptr;
    for (const auto &profile : profiles) {
        bool equal = true;
        for (unsigned i = 0; i < 10; ++i)
            if (firmware[i] != static_cast<uint8_t>(profile.family[i])) equal = false;
        if (equal) return &profile;
    }
    return nullptr;
}
}
#endif
"""
(root / "Sources/ECControl/ECFeatureProfiles.swift").write_text(swift)
(root / "Drivers/MSIECBridge/ECProfiles.hpp").write_text(cpp)
print(f"Generated {len(rows)} firmware families; source SHA256 {digest}")
