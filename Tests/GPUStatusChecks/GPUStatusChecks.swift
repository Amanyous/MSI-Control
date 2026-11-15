import Foundation

@main
struct GPUStatusChecks {
    static func main() {
        let valid = GPUStatus.decode([
            "Temperature(C)": 54,
            "GPU Core Utilization %": 0,
            "GPU Video Decode Utilization %": 100
        ])
        precondition(valid.temperature == 54 && valid.coreUsage == 0 && valid.videoDecodeUsage == 100)
        let invalid = GPUStatus.decode([
            "Temperature(C)": true,
            "GPU Core Utilization %": 101,
            "GPU Video Decode Utilization %": Double.nan
        ])
        precondition(invalid.temperature == nil && invalid.coreUsage == nil && invalid.videoDecodeUsage == nil)
        precondition(GPUStatus.decode([:]).coreUsage == nil)
        precondition(GPUStatus.decode([:], usedMemory: 25, totalMemory: 100).memoryUsage == 25)
        precondition(GPUStatus.decode([:], usedMemory: 0, totalMemory: 100).memoryUsage == 0)
        precondition(GPUStatus.decode([:], usedMemory: 101, totalMemory: 100).memoryUsage == nil)
        precondition(GPUStatus.decode([:], usedMemory: 1, totalMemory: 0).memoryUsage == nil)
        if let live = GPUStatus.read() {
            print("Live NVAccel: temperature=\(String(describing: live.temperature)), core=\(String(describing: live.coreUsage)), decode=\(String(describing: live.videoDecodeUsage)), VRAM=\(String(describing: live.memoryUsage))%")
        } else {
            print("NVAccel unavailable")
        }
        print("PASS GPU decoding: valid, zero, missing, boolean, out-of-range and nonfinite values")
    }
}
