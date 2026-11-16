import ECControl
import Foundation
import PowerServiceProtocol
import ServiceManagement

enum PerformanceAdministrator {
    private static let serviceRevision = 2
    private static let revisionKey = "mcontrol.hardwareServiceRevision"
    private static let registrationLock = NSLock()

    static func read() throws -> CPUPowerControlStatus {
        try ECBridgeConnection().powerControlStatus()
    }

    static var serviceEnabled: Bool {
        SMAppService.daemon(plistName: PowerServiceIdentity.plist).status == .enabled &&
            UserDefaults.standard.integer(forKey: revisionKey) == serviceRevision
    }

    static func requestAuthorization() throws {
        try prepareService(allowRegistration: true)
    }

    static func updateApprovedService() throws {
        guard SMAppService.daemon(plistName: PowerServiceIdentity.plist).status == .enabled else { return }
        try prepareService(allowRegistration: false)
    }

    private static func prepareService(allowRegistration: Bool) throws {
        registrationLock.lock()
        defer { registrationLock.unlock() }
        let service = SMAppService.daemon(plistName: PowerServiceIdentity.plist)
        let updating = service.status == .enabled &&
            UserDefaults.standard.integer(forKey: revisionKey) != serviceRevision
        if updating {
            let response = ServiceResponse()
            service.unregister { error in
                response.finish(error == nil ? Data() : nil, error?.localizedDescription)
            }
            _ = try response.wait()
        }
        if service.status != .enabled && (allowRegistration || updating) {
            do { try service.register() }
            catch {
                guard service.status == .requiresApproval else { throw error }
            }
        }
        guard service.status == .enabled else {
            if allowRegistration && service.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
            throw ECError.unavailable("请在系统设置 → 通用 → 登录项与扩展中允许 MSI Control 后台助手。首次批准后，性能、风扇控制和 EFI 挂载不再重复要求密码。")
        }
        UserDefaults.standard.set(serviceRevision, forKey: revisionKey)
    }

    static func apply(_ preset: CPUPowerPreset?, eco: Bool, expected: CPUPowerControlStatus,
                      allowRegistration: Bool = true) throws -> CPUPowerControlStatus {
        try prepareService(allowRegistration: allowRegistration)
        let request = PowerServiceRequest(preset: preset, eco: eco, expected: expected)
        let data = try send(try JSONEncoder().encode(request), hardware: false)
        let receipt = try JSONDecoder().decode(CPUPowerReceipt.self, from: data)
        guard receipt.verified else {
            throw ECError.unavailable(receipt.outcome == 1
                ? "写入校验失败，已恢复本次操作前的状态。"
                : "写入或恢复未能确认，已停止控制；请重新读取状态。")
        }
        Thread.sleep(forTimeInterval: 0.75)
        let status = try read()
        guard status.available, !status.conflict, status.current == receipt.package,
              status.shift == receipt.shift, status.fan == receipt.fan,
              status.preset == preset else {
            throw ECError.mismatch("延迟校验未通过，可能被固件或其他控制器覆盖；已停止自动写入。")
        }
        return status
    }

    static func control<T: Decodable>(_ request: HardwareServiceRequest, as type: T.Type) throws -> T {
        try prepareService(allowRegistration: true)
        let data = try send(try JSONEncoder().encode(request), hardware: true)
        return try JSONDecoder().decode(type, from: data)
    }

    private static func send(_ request: Data, hardware: Bool) throws -> Data {
        let connection = NSXPCConnection(machServiceName: PowerServiceIdentity.name, options: .privileged)
        connection.setCodeSigningRequirement(PowerServiceIdentity.serviceRequirement)
        connection.remoteObjectInterface = NSXPCInterface(with: PowerServiceProtocol.self)
        let response = ServiceResponse()
        connection.interruptionHandler = { response.finish(nil, "硬件助手连接中断；请重新读取状态") }
        connection.invalidationHandler = { response.finish(nil, "硬件助手连接不可用；请确认后台项目已批准") }
        connection.resume()
        defer { connection.invalidate() }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({
            response.finish(nil, $0.localizedDescription)
        }) as? PowerServiceProtocol else { throw ECError.unavailable("无法连接硬件助手") }
        if hardware {
            proxy.control(request) { data, error in response.finish(data, error) }
        } else {
            proxy.apply(request) { data, error in response.finish(data, error) }
        }
        return try response.wait()
    }
}

private final class ServiceResponse: @unchecked Sendable {
    private let lock = NSLock()
    private let completed = DispatchSemaphore(value: 0)
    private var result: Result<Data, Error>?

    func finish(_ data: Data?, _ error: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard result == nil else { return }
        if let data { result = .success(data) }
        else { result = .failure(ECError.unavailable(error ?? "硬件助手未返回结果")) }
        completed.signal()
    }

    func wait() throws -> Data {
        guard completed.wait(timeout: .now() + 10) == .success else {
            throw ECError.unavailable("硬件助手响应超时；未自动重试，请重新读取实际状态")
        }
        lock.lock()
        defer { lock.unlock() }
        return try result!.get()
    }
}
