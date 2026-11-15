import Foundation
import IOKit

enum WindowsNumLock {
    static let preference = "mcontrol.windowsNumLock"

    static func lockState() -> Bool? {
        guard UserDefaults.standard.bool(forKey: preference) else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("ApplePS2Keyboard"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "MSINumLockState" as CFString,
                                               kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
    }

    static func apply(_ enabled: Bool) -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("ApplePS2Keyboard"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        guard (IORegistryEntryCreateCFProperty(service, "MSIWindowsNumLockSupport" as CFString,
                                               kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool) == true
        else { return false }
        // The driver superclass may return unsupported after applying its own properties.
        _ = IORegistryEntrySetCFProperty(service, "NumLockSupport" as CFString,
                                        enabled ? kCFBooleanTrue : kCFBooleanFalse)
        return (IORegistryEntryCreateCFProperty(service, "NumLockSupport" as CFString,
                                                kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool) == enabled
    }
}
