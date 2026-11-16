import AppKit
import ECControl
import PowerServiceProtocol
import SwiftUI

private enum EFIService {
    typealias Partition = SystemEFIPartition

    static func find() throws -> Partition {
        try SystemEFI.find()
    }

    static func perform(mount: Bool, partition: Partition) throws -> Partition {
        let updated = try PerformanceAdministrator.control(
            .efi(EFIServiceRequest(mount: mount, expected: partition)), as: SystemEFIPartition.self)
        guard updated.identifier == partition.identifier, updated.uuid == partition.uuid,
              (updated.mountPoint != nil) == mount else {
            throw ECError.mismatch("EFI 挂载状态校验失败")
        }
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
        case .failure(let error): message = error.localizedDescription
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
            Text("首次批准 MSI Control 后台助手后，挂载与卸载无需重复输入密码。")
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
