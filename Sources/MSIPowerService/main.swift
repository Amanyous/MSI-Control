import ECControl
import Foundation
import PowerServiceProtocol

final class PowerService: NSObject, PowerServiceProtocol, NSXPCListenerDelegate, @unchecked Sendable {
    private let transactions = DispatchQueue(label: "org.shenying.mcontrol.power.transactions")

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier != 0 else { return false }
        connection.setCodeSigningRequirement(PowerServiceIdentity.appRequirement)
        connection.exportedInterface = NSXPCInterface(with: PowerServiceProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func ping(reply: @escaping (Int) -> Void) {
        reply(PowerServiceIdentity.version)
    }

    func apply(_ data: Data, reply: @escaping (Data?, String?) -> Void) {
        // Serialize complete CAS transactions across all accepted connections.
        let response = Reply(reply)
        transactions.async {
            do {
                guard data.count <= 2048 else { throw ECError.invalid("功耗请求过大") }
                let request = try JSONDecoder().decode(PowerServiceRequest.self, from: data)
                _ = try request.validatedStatus()
                let bridge = try ECBridgeConnection()
                let current = try bridge.powerControlStatus()
                try request.validateCurrent(current)
                let receipt = try bridge.setPowerPreset(
                    CPUPowerPreset(rawValue: request.mode), eco: request.eco, expected: current)
                response.block(try JSONEncoder().encode(receipt), nil)
            } catch {
                response.block(nil, error.localizedDescription)
            }
        }
    }

    func control(_ data: Data, reply: @escaping (Data?, String?) -> Void) {
        let response = Reply(reply)
        transactions.async {
            do {
                guard data.count <= 4096 else { throw ECError.invalid("硬件请求过大") }
                let request = try JSONDecoder().decode(HardwareServiceRequest.self, from: data)
                let result: Data
                switch request {
                case .fan(let fan):
                    try fan.validate()
                    result = try fan.execute(on: ECBridgeConnection())
                case .efi(let efi):
                    result = try JSONEncoder().encode(SystemEFI.perform(efi))
                }
                response.block(result, nil)
            } catch {
                response.block(nil, error.localizedDescription)
            }
        }
    }

    private final class Reply: @unchecked Sendable {
        let block: (Data?, String?) -> Void
        init(_ block: @escaping (Data?, String?) -> Void) { self.block = block }
    }
}

guard getuid() == 0 else {
    FileHandle.standardError.write(Data("MSIPowerService must be managed by the system.\n".utf8))
    exit(1)
}
let service = PowerService()
let listener = NSXPCListener(machServiceName: PowerServiceIdentity.name)
listener.setConnectionCodeSigningRequirement(PowerServiceIdentity.appRequirement)
listener.delegate = service
listener.resume()
RunLoop.current.run()
