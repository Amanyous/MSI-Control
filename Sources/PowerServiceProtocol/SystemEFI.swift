import ECControl
import Foundation

public struct SystemEFIPartition: Codable, Equatable, Sendable {
    public let identifier: String
    public let uuid: UUID
    public let mountPoint: String?

    public init(identifier: String, uuid: UUID, mountPoint: String?) {
        self.identifier = identifier
        self.uuid = uuid
        self.mountPoint = mountPoint
    }
}

public struct EFIServiceRequest: Codable, Sendable {
    public let mount: Bool
    public let expected: SystemEFIPartition

    public init(mount: Bool, expected: SystemEFIPartition) {
        self.mount = mount
        self.expected = expected
    }

    public func validate(current: SystemEFIPartition) throws {
        guard expected.identifier.range(of: #"^disk[0-9]+s[0-9]+$"#, options: .regularExpression) != nil,
              current.identifier == expected.identifier, current.uuid == expected.uuid,
              current.mountPoint == expected.mountPoint else {
            throw ECError.mismatch("系统 EFI 分区或挂载状态已变化，请刷新后重试")
        }
    }
}

public enum SystemEFI {
    private static func run(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ECError.unavailable("EFI 操作未完成，请检查分区是否正在使用")
        }
        return data
    }

    private static func plist(_ arguments: [String]) throws -> [String: Any] {
        let data = try run(arguments)
        guard let result = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ECError.invalid("磁盘信息格式无效")
        }
        return result
    }

    public static func find() throws -> SystemEFIPartition {
        let root = try plist(["info", "-plist", "/"])
        let stores = root["APFSPhysicalStores"] as? [[String: Any]]
        let physical = stores?.compactMap { $0["APFSPhysicalStore"] as? String } ?? []
        var disks = Set<String>()
        if physical.isEmpty {
            if let parent = root["ParentWholeDisk"] as? String { disks.insert(parent) }
        } else {
            for store in physical {
                if let parent = try plist(["info", "-plist", store])["ParentWholeDisk"] as? String {
                    disks.insert(parent)
                }
            }
        }
        guard disks.count == 1, let disk = disks.first,
              disk.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil else {
            throw ECError.unavailable("未找到唯一的系统 EFI 分区")
        }
        let list = try plist(["list", "-plist", disk])
        let devices = list["AllDisksAndPartitions"] as? [[String: Any]] ?? []
        let candidates = devices.flatMap { $0["Partitions"] as? [[String: Any]] ?? [] }.filter {
            let content = $0["Content"] as? String
            return content == "EFI" || content?.uppercased() == "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
        }
        guard candidates.count == 1, let identifier = candidates.first?["DeviceIdentifier"] as? String,
              identifier.range(of: #"^disk[0-9]+s[0-9]+$"#, options: .regularExpression) != nil else {
            throw ECError.unavailable("未找到唯一的系统 EFI 分区")
        }
        let info = try plist(["info", "-plist", identifier])
        guard info["ParentWholeDisk"] as? String == disk,
              info["DeviceIdentifier"] as? String == identifier,
              let rawUUID = info["DiskUUID"] as? String, let uuid = UUID(uuidString: rawUUID),
              let content = info["Content"] as? String,
              content == "EFI" || content.uppercased() == "C12A7328-F81F-11D2-BA4B-00A0C93EC93B" else {
            throw ECError.invalid("系统 EFI 身份无法确认")
        }
        let mount = info["MountPoint"] as? String
        return SystemEFIPartition(identifier: identifier, uuid: uuid,
                                  mountPoint: mount?.isEmpty == false ? mount : nil)
    }

    public static func perform(_ request: EFIServiceRequest) throws -> SystemEFIPartition {
        let current = try find()
        try request.validate(current: current)
        if (current.mountPoint != nil) != request.mount {
            _ = try run([request.mount ? "mount" : "unmount", "/dev/\(current.identifier)"])
        }
        let updated = try find()
        guard updated.identifier == current.identifier, updated.uuid == current.uuid,
              (updated.mountPoint != nil) == request.mount else {
            throw ECError.mismatch("EFI 挂载状态校验失败，请刷新")
        }
        return updated
    }
}
