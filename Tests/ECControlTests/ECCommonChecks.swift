import Foundation
import ECControl

@main
struct ECCommonChecks {
    static func main() {
        let old = ECFeatureProfile.match("14C1EMS1.199")!
        let new = ECFeatureProfile.match("15P2EMS1.110")!
        precondition(!old.fnWinInverted && new.fnWinInverted)
        precondition(old.fnWinAddress == 0xBF && new.fnWinAddress == 0xE8)
        for profile in [old, new] {
            for number in 0...255 {
                let byte = UInt8(number)
                for desired: UInt8 in [0, 1] {
                    let value = ECCommonPolicy.target(profile: profile, feature: .winKeyLeft,
                                                      desired: desired, current: byte)!
                    let mask: UInt8 = 1 << profile.fnWinBit
                    precondition(value & ~mask == byte & ~mask)
                    precondition(((value & mask != 0) != profile.fnWinInverted) == (desired == 1))
                }
            }
            for mode in profile.shiftModes {
                precondition(ECCommonPolicy.target(profile: profile, feature: .shift,
                                                    desired: mode.value, current: profile.shiftModes[0].value) == mode.value)
            }
            precondition(ECCommonPolicy.target(profile: profile, feature: .shift, desired: 0xFF, current: 0xC1) == nil)
        }
        for firmware in ["159KIMS1.199", "15H5EMS1.199", "13P5EMS1.199"] {
            precondition(ECFeatureProfile.match(firmware)?.webcamAddress == nil)
        }
        let legacy = ECFeatureProfile.match("16P5EMS1.199")!
        precondition(legacy.namedFanModes.map(\.value) == [0x0C, 0x4C, 0x8C])
        precondition(ECCommonPolicy.target(profile: legacy, feature: .fan, desired: 0x8C, current: 0x0C) == 0x8C)
        precondition(!ECChargePolicy.validCurrent(80) && ECChargePolicy.validCurrent(0xD0))
        print("PASS common EC codecs: inversion, bit preservation, unsupported webcam, Shift and legacy fan modes; no hardware accessed.")
    }
}
