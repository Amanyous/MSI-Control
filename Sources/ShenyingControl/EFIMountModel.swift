import AppKit
import SwiftUI

private enum EFIService {
    struct Partition: Sendable {
        let identifier: String
        let mountPoint: String?
    }
    enum Failure: Error { case unavailable, cancelled, operation }

    static func run(_ executable: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.operation }
        return data
    }

    static func plist(_ arguments: [String]) throws -> [String: Any] {
        let data = try run("/usr/sbin/diskutil", arguments)
        guard let result = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw Failure.unavailable
        }
        return result
    }

    static func find() throws -> Partition {
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
        // Multi-store systems are ambiguous: never choose an arbitrary ESP.
        guard disks.count == 1, let disk = disks.first else { throw Failure.unavailable }
        let list = try plist(["list", "-plist", disk])
        let devices = list["AllDisksAndPartitions"] as? [[String: Any]] ?? []
        let partitions = devices.flatMap { $0["Partitions"] as? [[String: Any]] ?? [] }
        let candidates = partitions.filter {
            let content = $0["Content"] as? String
            return content == "EFI" || content?.uppercased() == "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
        }
        guard candidates.count == 1, let identifier = candidates.first?["DeviceIdentifier"] as? String,
              identifier.range(of: #"^disk[0-9]+s[0-9]+$"#, options: .regularExpression) != nil else {
            throw Failure.unavailable
        }
        let info = try plist(["info", "-plist", identifier])
        let mount = info["MountPoint"] as? String
        return Partition(identifier: identifier, mountPoint: mount?.isEmpty == false ? mount : nil)
    }

    static func perform(mount: Bool, partition: Partition) throws -> Partition {
        // The only interpolated value is a validated disk identifier, never a path or user input.
        let verb = mount ? "mount" : "unmount"
        let script = """
        try
            do shell script "/usr/sbin/diskutil \(verb) /dev/\(partition.identifier)" with administrator privileges
        on error message number code
            if code is -128 then return "CANCELLED"
            error message number code
        end try
        """
        let output = try run("/usr/bin/osascript", ["-e", script])
        if String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "CANCELLED" {
            throw Failure.cancelled
        }
        let updated = try find()
        guard updated.identifier == partition.identifier,
              (updated.mountPoint != nil) == mount else { throw Failure.operation }
        return updated
    }
}

@MainActor
final class EFIMountModel: ObservableObject {
    @Published private(set) var mountPoint: String?
    @Published private(set) var isBusy = false
    @Published private(set) var message = ""
    @Published private(set) var feedbackID = UUID()

    func refresh() async {
        guard !isBusy else { return }
        isBusy = true
        let partition = await Task.detached(priority: .utility) { try? EFIService.find() }.value
        mountPoint = partition?.mountPoint
        isBusy = false
    }

    func changeMount(mount: Bool) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let result = await Task.detached(priority: .userInitiated) { () -> Result<EFIService.Partition, Error> in
            Result {
                let partition = try EFIService.find()
                if (partition.mountPoint != nil) == mount { return partition }
                return try EFIService.perform(mount: mount, partition: partition)
            }
        }.value
        switch result {
        case .success(let partition):
            mountPoint = partition.mountPoint
            message = mount ? "EFI 已挂载" : "EFI 已卸载"
            if mount { open() }
        case .failure(EFIService.Failure.cancelled): message = "操作已取消"
        case .failure(EFIService.Failure.unavailable): message = "未找到唯一的系统 EFI 分区"
        case .failure: message = "操作未完成，请检查分区是否正在使用"
        }
        feedbackID = UUID()
    }

    func open() {
        guard let mountPoint else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: mountPoint, isDirectory: true))
    }
}

struct EFIMountSection: View {
    @StateObject private var model = EFIMountModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showToast = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("系统引导配置").font(.headline)
            HStack(spacing: 12) {
                if model.mountPoint != nil {
                    Button("在 Finder 中显示", systemImage: "folder") { model.open() }
                        .buttonStyle(.bordered)
                    Button("卸载 EFI", systemImage: "eject") {
                        Task { await model.changeMount(mount: false) }
                    }.buttonStyle(.bordered)
                } else {
                    Button("挂载 EFI 分区", systemImage: "externaldrive.badge.plus") {
                        Task { await model.changeMount(mount: true) }
                    }.buttonStyle(.borderedProminent)
                }
                if model.isBusy { ProgressView().controlSize(.small) }
            }
            .disabled(model.isBusy)
            Text("挂载 ESP 分区以编辑 OpenCore 配置文件（需要管理员权限）。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await model.refresh() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            Task { await model.refresh() }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            Task { await model.refresh() }
        }
        .overlay(alignment: .top) {
            if showToast {
                Text(model.message)
                    .font(.subheadline).padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .task(id: model.feedbackID) {
            guard !model.message.isEmpty else { return }
            withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8)) { showToast = true }
            do {
                try await Task.sleep(for: .seconds(2))
                withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8)) { showToast = false }
            } catch {}
        }
    }
}
