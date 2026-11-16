import AppKit
import Foundation

@MainActor
enum OpenCoreDriverInstaller {
    static func install() -> String {
        let panel = NSOpenPanel()
        panel.title = t("choose_opencore_config_plist_or_efi_folder")
        panel.message = t("select_efi_oc_config_plist_an_efi_volume_or_an_efi_oc_folder_mount_efi")
        panel.prompt = t("choose")
        panel.directoryURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        guard panel.runModal() == .OK, let selected = panel.url else { return "已取消。" }

        guard let (oc, configURL) = locateOpenCoreConfig(from: selected) else {
            return "在所选位置找不到 config.plist。\n\n你选的是：\(selected.path)\n\n请在文件选择窗口进入已挂载的 EFI 分区，直接选择 EFI/OC/config.plist。"
        }
        let kextURL = oc.appendingPathComponent("Kexts/MSIECBridge.kext", isDirectory: true)
        let bundledKext = bundledKextURL()
        guard let bundledKext,
              FileManager.default.fileExists(atPath: bundledKext.appendingPathComponent("Contents/Info.plist").path),
              FileManager.default.fileExists(atPath: bundledKext.appendingPathComponent("Contents/MacOS/MSIECBridge").path) else {
            return "MSI Control.app 内缺少 MSIECBridge.kext。请重新下载并解压完整 MSI Control 更新包。"
        }
        guard let data = try? Data(contentsOf: bundledKext.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "org.shenying.msiecbridge",
              info["CFBundleExecutable"] as? String == "MSIECBridge",
              let driverVersion = info["CFBundleShortVersionString"] as? String,
              !driverVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              FileManager.default.isExecutableFile(atPath: bundledKext.appendingPathComponent("Contents/MacOS/MSIECBridge").path) else {
            return "包内 EC 驱动身份、版本信息或可执行文件无效。请重新下载完整应用包，未修改 EFI。"
        }

        let confirm = NSAlert()
        confirm.alertStyle = .warning
        confirm.messageText = t("modify_opencore_efi")
        confirm.informativeText = "目标：\(oc.path)\n\n将备份 config.plist 和现有 EC 驱动，再安装 MSIECBridge \(driverVersion) 并在 Kernel → Add 中启用。CPU 频率接口只读，日常读取无需管理员授权；EC 写入仍要求管理员授权。此 Kext 尚未在目标机验证；请保留可启动的备用 EFI，若启动异常可从备份恢复。"
        confirm.addButton(withTitle: t("back_up_and_install"))
        confirm.addButton(withTitle: t("cancel"))
        guard confirm.runModal() == .alertFirstButtonReturn else { return "已取消，EFI 未修改。" }

        do {
            return try install(into: oc, configURL: configURL, sourceKext: bundledKext, destinationKext: kextURL)
        } catch {
            return "安装失败：\(error.localizedDescription)"
        }
    }

    private static func locateOpenCoreConfig(from selected: URL) -> (oc: URL, config: URL)? {
        let fm = FileManager.default
        if selected.lastPathComponent == "config.plist", fm.fileExists(atPath: selected.path) {
            return (selected.deletingLastPathComponent(), selected)
        }

        let candidates: [URL]
        if selected.lastPathComponent == "OC" {
            candidates = [selected]
        } else {
            candidates = [
                selected.appendingPathComponent("EFI/OC", isDirectory: true),
                selected.appendingPathComponent("OC", isDirectory: true),
                selected
            ]
        }
        for oc in candidates {
            let config = oc.appendingPathComponent("config.plist")
            if fm.fileExists(atPath: config.path) { return (oc, config) }
        }
        return nil
    }

    private static func bundledKextURL() -> URL? {
        let fileManager = FileManager.default
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("MSIECBridge.kext", isDirectory: true),
            Bundle.main.resourceURL?.appendingPathComponent("MSIControl_MSIControl.bundle/Resources/MSIECBridge.kext", isDirectory: true),
            URL(fileURLWithPath: fileManager.currentDirectoryPath)
                .appendingPathComponent("Sources/ShenyingControl/Resources/MSIECBridge.kext", isDirectory: true)
        ].compactMap { $0 }
        return candidates.first { fileManager.fileExists(atPath: $0.appendingPathComponent("Contents/Info.plist").path) }
    }

    private static func install(into oc: URL, configURL: URL, sourceKext: URL, destinationKext: URL) throws -> String {
        let fm = FileManager.default
        let configData = try Data(contentsOf: configURL)
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard var config = try PropertyListSerialization.propertyList(from: configData, options: [.mutableContainersAndLeaves], format: &format) as? [String: Any],
              var kernel = config["Kernel"] as? [String: Any] else {
            throw InstallerError.invalidConfig
        }
        var add = kernel["Add"] as? [[String: Any]] ?? []

        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let configBackup = oc.appendingPathComponent("config.plist.backup-\(stamp)")
        let kextBackup = oc.appendingPathComponent("Kexts/MSIECBridge.kext.backup-\(stamp)", isDirectory: true)
        let kextParent = destinationKext.deletingLastPathComponent()
        try fm.createDirectory(at: kextParent, withIntermediateDirectories: true)
        try fm.copyItem(at: configURL, to: configBackup)

        var movedOldKext = false
        do {
            if fm.fileExists(atPath: destinationKext.path) {
                try fm.moveItem(at: destinationKext, to: kextBackup)
                movedOldKext = true
            }
            try fm.copyItem(at: sourceKext, to: destinationKext)
            try signAndVerify(destinationKext)

            add.removeAll { ($0["BundlePath"] as? String) == "MSIECBridge.kext" }
            add.append([
                "Arch": "x86_64",
                "BundlePath": "MSIECBridge.kext",
                "Comment": "MSI Control on-demand EC and charge limit",
                "Enabled": true,
                "ExecutablePath": "Contents/MacOS/MSIECBridge",
                "MaxKernel": "",
                "MinKernel": "",
                "PlistPath": "Contents/Info.plist"
            ])
            kernel["Add"] = add
            config["Kernel"] = kernel
            let updated = try PropertyListSerialization.data(fromPropertyList: config, format: format, options: 0)
            try updated.write(to: configURL, options: .atomic)
            UserDefaults.standard.set(true, forKey: "mcontrol.ecConfiguredByApp")
            return "EC 读写驱动配置完成。\n\nconfig.plist 备份：\(configBackup.lastPathComponent)\n旧驱动备份：\(movedOldKext ? kextBackup.lastPathComponent : "无")\n\n请重启并从 OpenCore 启动，再进入电池设置点击“读取 EC”。启动过程不会读写 EC；充电写入需要匹配固件并授权。此版本尚未在目标笔记本实测。"
        } catch {
            if fm.fileExists(atPath: destinationKext.path) { try? fm.removeItem(at: destinationKext) }
            if movedOldKext { try? fm.moveItem(at: kextBackup, to: destinationKext) }
            throw error
        }
    }

    private static func signAndVerify(_ kext: URL) throws {
        // Desktop/workspace copies can carry FinderInfo/resource-fork metadata;
        // codesign rejects those attributes on a bundle.
        try run("/usr/bin/xattr", ["-cr", kext.path])
        try run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", "--timestamp=none", kext.path])
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "--verbose=2", kext.path])
    }

    private static func run(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw InstallerError.commandFailed(message.isEmpty ? path : message) }
    }

    private enum InstallerError: LocalizedError {
        case invalidConfig
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidConfig: "config.plist 无法解析，未能安全更新。原文件保留且已生成备份。"
            case let .commandFailed(message): "签名或签名校验失败：\(message)"
            }
        }
    }
}
