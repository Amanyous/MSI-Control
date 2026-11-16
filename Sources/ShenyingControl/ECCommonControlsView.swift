import SwiftUI
import ECControl

@MainActor
final class ECCommonControlsModel: ObservableObject {
    @Published private(set) var snapshot: ECCommonSnapshot?
    @Published private(set) var busy = false
    @Published private(set) var error: String?

    func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            snapshot = try await Task.detached { try ECBridgeConnection().commonSnapshot() }.value
            error = nil
        } catch {
            snapshot = nil
            self.error = error.localizedDescription
        }
    }

    func apply(_ feature: ECCommonFeature, desired: UInt8) {
        guard !busy, let snapshot, snapshot.api >= 11,
              let expected = snapshot.rawValue(for: feature),
              let target = ECCommonPolicy.target(profile: snapshot.profile, feature: feature, desired: desired, current: expected) else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let receipt = try await Task.detached {
                    try ECCommonAdministrator.apply(feature, desired: desired, expected: expected, firmware: snapshot.firmware)
                }.value
                guard receipt.firmware == snapshot.firmware, receipt.feature == feature,
                      receipt.desired == desired, receipt.before == expected, receipt.after == target else {
                    throw ECError.mismatch("EC readback mismatch")
                }
                self.snapshot = try await Task.detached { try ECBridgeConnection().commonSnapshot() }.value
            } catch {
                self.snapshot = nil
                self.error = error.localizedDescription
            }
        }
    }
}

private enum ECCommonAdministrator {
    static func apply(_ feature: ECCommonFeature, desired: UInt8, expected: UInt8, firmware: String) throws -> ECCommonReceipt {
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "MSIECHelper"),
              FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw ECError.unavailable("Missing MSIECHelper")
        }
        let args = [helper.path, "set-common", String(feature.rawValue), String(desired), String(expected), firmware]
        let command = args.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        let literal = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(literal)\" with administrator privileges"]
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output; process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ECError.unavailable(String(data: errorData, encoding: .utf8) ?? "EC write failed")
        }
        return try JSONDecoder().decode(ECCommonReceipt.self, from: data)
    }
}

struct ECCommonControlsView: View {
    @EnvironmentObject private var localization: AppLocalization
    @StateObject private var model = ECCommonControlsModel()
    private var chinese: Bool { localization.resolvedLanguage == .chinese }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let snapshot = model.snapshot {
                if let enabled = snapshot.webcamEnabled {
                    Toggle(chinese ? "摄像头" : "Webcam", isOn: Binding(
                        get: { enabled }, set: { model.apply(.webcam, desired: $0 ? 1 : 0) }
                    )).toggleStyle(.switch)
                        .disabled(model.busy || snapshot.api < 11 ||
                                  snapshot.webcamBlocked == nil || snapshot.webcamBlocked == true)
                    if snapshot.webcamBlocked == true {
                        Text(chinese ? "EC 报告摄像头已锁定" : "The EC reports the webcam is blocked")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let left = snapshot.winKeyLeft {
                    Picker(chinese ? "Fn 与 Win 键布局" : "Fn and Win Key Layout", selection: Binding(
                        get: { left }, set: { model.apply(.winKeyLeft, desired: $0 ? 1 : 0) }
                    )) {
                        Text(chinese ? "左 Win · 右 Fn" : "Win Left · Fn Right").tag(true)
                        Text(chinese ? "左 Fn · 右 Win" : "Fn Left · Win Right").tag(false)
                    }.pickerStyle(.menu).disabled(model.busy || snapshot.api < 11)
                }
                if snapshot.api < 11 {
                    Text(chinese ? "新增控制需要 MSIECBridge 0.3.8 / API 11，配置后重启。"
                         : "New controls require MSIECBridge 0.3.8 / API 11 and a restart.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.busy { ProgressView().controlSize(.small) }
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Button(chinese ? "重试" : "Retry") {
                    Task { await model.refresh() }
                }.disabled(model.busy)
            }
        }
        .task {
            await model.refresh()
        }
    }
}
