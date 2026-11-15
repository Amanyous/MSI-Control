import Foundation
import IOKit
import IOKit.hid

public enum KeyboardHIDService {
    public static func scan() -> LightingReport {
        let (records, error) = enumerate()
        return LightingReport(createdAt: Date(), scan: LightingScan(devices: records.map(\.info), error: error), result: nil)
    }

    public static func perform(_ action: LightingAction, expectedDeviceID: UInt64) -> LightingReport {
        // Re-enumerate at the moment of writing. Never reuse a stale device path.
        let (records, error) = enumerate()
        let scan = LightingScan(devices: records.map(\.info), error: error)
        let matching = records.filter { $0.info.supportsTrial }
        let result: LightingResult
        if error != nil || matching.count != 1 {
            result = LightingTransaction.rejected(action, message: "\(scan.status)，未发送报文")
        } else if matching[0].info.id != expectedDeviceID {
            result = LightingTransaction.rejected(action, message: "灯控设备已变化，请刷新接口后重试；未发送报文")
        } else {
            result = LightingTransaction.perform(action, device: matching[0].info, transport: DeviceTransport(device: matching[0].device))
        }
        return LightingReport(createdAt: Date(), scan: scan, result: result)
    }

    private struct Record {
        let info: LightingDevice
        let device: IOHIDDevice
    }

    private static func enumerate() -> ([Record], String?) {
        guard let matching = IOServiceMatching(kIOHIDDeviceKey) else { return ([], "无法创建 HID 查询") }
        var iterator: io_iterator_t = 0
        let status = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard status == KERN_SUCCESS else { return ([], "HID 枚举失败：\(LightingTransaction.hexCode(status))") }
        defer { IOObjectRelease(iterator) }
        var records: [Record] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != IO_OBJECT_NULL else { break }
            defer { IOObjectRelease(service) }
            guard let device = IOHIDDeviceCreate(kCFAllocatorDefault, service) else { continue }
            let vendor = number(device, kIOHIDVendorIDKey)
            // Diagnostic inventory only; writes remain restricted to 1462:1603.
            guard vendor == 0x1462 || vendor == 0x1770 else { continue }
            var registryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &registryID) == KERN_SUCCESS else { continue }
            let descriptor = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data
            let info = LightingDevice(
                id: registryID, vendorID: vendor, productID: number(device, kIOHIDProductIDKey),
                name: string(device, kIOHIDProductKey), manufacturer: string(device, kIOHIDManufacturerKey),
                transport: string(device, kIOHIDTransportKey), usagePage: number(device, kIOHIDPrimaryUsagePageKey),
                usage: number(device, kIOHIDPrimaryUsageKey), maximumFeatureBytes: number(device, kIOHIDMaxFeatureReportSizeKey),
                featureReports: descriptor.flatMap(HIDFeatureLayout.parse),
                descriptorHex: descriptor.map { LightingTransaction.hexBytes([UInt8]($0)) }
            )
            records.append(Record(info: info, device: device))
        }
        return (records.sorted { $0.info.id < $1.info.id }, nil)
    }

    private static func number(_ device: IOHIDDevice, _ key: String) -> Int {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? 0
    }

    private static func string(_ device: IOHIDDevice, _ key: String) -> String {
        IOHIDDeviceGetProperty(device, key as CFString) as? String ?? "未知"
    }

    private struct DeviceTransport: LightingTransport {
        let device: IOHIDDevice
        func open() -> Int32 { IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
        func close() { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
        func send(_ bytes: [UInt8]) -> Int32 {
            // Like hidapi/mac, keep the leading byte for a nonzero Report ID.
            bytes.withUnsafeBufferPointer { buffer in
                IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 2, buffer.baseAddress!, buffer.count)
            }
        }
        func readReply() -> (code: Int32, bytes: [UInt8]) {
            var bytes = [UInt8](repeating: 0, count: 64)
            bytes[0] = 1
            var length = bytes.count
            let code = bytes.withUnsafeMutableBufferPointer { buffer in
                IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, buffer.baseAddress!, &length)
            }
            return (code, code == 0 ? Array(bytes.prefix(max(0, min(length, bytes.count)))) : [])
        }
    }
}
