#include "ECPolicy.hpp"
#include <IOKit/IOService.h>
#include <IOKit/IOUserClient.h>
#include <IOKit/IOLocks.h>
#include <IOKit/acpi/IOACPIPlatformDevice.h>
#include <libkern/c++/OSBoolean.h>
#include <libkern/c++/OSData.h>
#include <mach/kmod.h>
#include <i386/proc_reg.h>

static kern_return_t msiec_start(kmod_info *, void *) { return KMOD_RETURN_SUCCESS; }
static kern_return_t msiec_stop(kmod_info *, void *) { return KMOD_RETURN_SUCCESS; }
KMOD_EXPLICIT_DECL(org_shenying_msiecbridge, "0.3.6", msiec_start, msiec_stop)

class MSIEmbeddedControllerBridge : public IOService {
    OSDeclareDefaultStructors(MSIEmbeddedControllerBridge)
    IOLock *lock {nullptr};
    IOACPIPlatformDevice *ec {nullptr};
    IOReturn read(uint8_t address, uint8_t *value);
    IOReturn readFirmware(uint8_t *bytes);
public:
    bool start(IOService *provider) override;
    void stop(IOService *provider) override;
    void free() override;
    IOReturn newUserClient(task_t task, void *securityID, UInt32 type,
                          OSDictionary *properties, IOUserClient **handler) override;
    IOReturn copyFirmware(uint8_t *bytes);
    IOReturn readRegister(uint64_t address, uint64_t *value);
    IOReturn setLimit(uint64_t percent, uint64_t expected, uint64_t *before, uint64_t *after);
    IOReturn setFanMode(uint64_t mode, uint64_t expected, uint64_t *before, uint64_t *after);
    IOReturn setCoolerBoost(uint64_t enabled, uint64_t expected, uint64_t *before, uint64_t *after);
    IOReturn setFanCurve(const uint8_t *request, uint8_t *receipt);
    IOReturn setPerformance(const uint64_t *request, uint64_t *receipt);
    IOReturn readFanCounters(uint64_t *output);
    IOReturn setMuteLED(uint64_t led, uint64_t enabled, uint64_t *output);
};

class MSIECUserClient : public IOUserClient {
    OSDeclareDefaultStructors(MSIECUserClient)
    MSIEmbeddedControllerBridge *bridge {nullptr};
    static IOReturn firmwareCall(OSObject *, void *, IOExternalMethodArguments *);
    static IOReturn readCall(OSObject *, void *, IOExternalMethodArguments *);
    static IOReturn limitCall(OSObject *, void *, IOExternalMethodArguments *);
    static IOReturn fanModeCall(OSObject *, void *, IOExternalMethodArguments *);
    static IOReturn coolerBoostCall(OSObject *, void *, IOExternalMethodArguments *);
    static IOReturn fanCurveCall(OSObject *, void *, IOExternalMethodArguments *);
    static IOReturn performanceCall(OSObject *, void *, IOExternalMethodArguments *);
    static IOReturn frequencyCall(OSObject *, void *, IOExternalMethodArguments *);
    static IOReturn fanCountersCall(OSObject *, void *, IOExternalMethodArguments *);
    static IOReturn muteLEDCall(OSObject *, void *, IOExternalMethodArguments *);
    static IOReturn touchpadCall(OSObject *, void *, IOExternalMethodArguments *);
public:
    bool initWithTask(task_t task, void *securityID, UInt32 type, OSDictionary *properties) override;
    bool start(IOService *provider) override;
    IOReturn clientClose() override;
    IOReturn externalMethod(uint32_t selector, IOExternalMethodArguments *arguments,
                           IOExternalMethodDispatch *dispatch = nullptr,
                           OSObject *target = nullptr, void *reference = nullptr) override;
};

OSDefineMetaClassAndStructors(MSIEmbeddedControllerBridge, IOService)
OSDefineMetaClassAndStructors(MSIECUserClient, IOUserClient)

bool MSIEmbeddedControllerBridge::start(IOService *provider) {
    if (!IOService::start(provider)) return false;
    // AppleACPIEC is the provider; its ACPI nub owns the system address-space API.
    // IOProviderClass is AppleACPIEC; its provider is the ACPI nub that owns
    // the system address-space handler. Keep this lookup lazy-safe and do not
    // assume the AppleACPIEC object itself implements readAddressSpace.
    ec = OSDynamicCast(IOACPIPlatformDevice, provider);
    if (!ec) ec = OSDynamicCast(IOACPIPlatformDevice, provider->getProvider());
    if (!ec) return false;
    lock = IOLockAlloc();
    if (!lock) return false;
    setProperty("MSIECAPI", MSIECPolicy::apiVersion, 32);
    setProperty("MSIECStatus", "Ready; explicit user requests only");
    setProperty("MSIECProfile", "not-probed");
    setProperty("MSIECWriteEnabled", kOSBooleanFalse);
    // No ACPI evaluation, EC reads, timer, or writes during startup.
    registerService();
    return true;
}

void MSIEmbeddedControllerBridge::stop(IOService *provider) {
    if (lock) {
        IOLockLock(lock);
        ec = nullptr;
        IOLockUnlock(lock);
    }
    IOService::stop(provider);
}

void MSIEmbeddedControllerBridge::free() {
    if (lock) { IOLockFree(lock); lock = nullptr; }
    IOService::free();
}

IOReturn MSIEmbeddedControllerBridge::read(uint8_t address, uint8_t *value) {
    if (!ec || isInactive()) return kIOReturnNotReady;
    UInt64 raw = 0;
    IOACPIAddress location {};
    location.addr64 = address;
    const auto result = ec->readAddressSpace(&raw, kIOACPIAddressSpaceIDEmbeddedController, location, 8, 0, 0);
    if (result == kIOReturnSuccess) *value = static_cast<uint8_t>(raw);
    return result;
}

IOReturn MSIEmbeddedControllerBridge::readFirmware(uint8_t *bytes) {
    for (uint32_t index = 0; index < MSIECPolicy::firmwareLength; ++index) {
        const auto result = read(static_cast<uint8_t>(MSIECPolicy::firmwareAddress + index), &bytes[index]);
        if (result != kIOReturnSuccess) {
            removeProperty("MSIECIdentityA0");
            setProperty("MSIECProfile", "read-failed");
            setProperty("MSIECWriteEnabled", kOSBooleanFalse);
            return result;
        }
    }
    setProperty("MSIECIdentityA0", bytes, MSIECPolicy::firmwareLength);
    const bool supported = MSIECPolicy::supportsCharge(bytes);
    const bool fanSupported = MSIECPolicy::supportsFan(bytes);
    setProperty("MSIECProfile", fanSupported ? "15P2-charge-fan" : supported ? "15P4-charge" : "unknown-read-only");
    setProperty("MSIECWriteEnabled", supported || fanSupported);
    return kIOReturnSuccess;
}

IOReturn MSIEmbeddedControllerBridge::copyFirmware(uint8_t *bytes) {
    IOLockLock(lock);
    const auto result = readFirmware(bytes);
    IOLockUnlock(lock);
    return result;
}

IOReturn MSIEmbeddedControllerBridge::readRegister(uint64_t address, uint64_t *value) {
    if (address > 255) return kIOReturnBadArgument;
    uint8_t raw = 0;
    IOLockLock(lock);
    const auto result = read(static_cast<uint8_t>(address), &raw);
    IOLockUnlock(lock);
    if (result == kIOReturnSuccess) *value = raw;
    return result;
}

IOReturn MSIEmbeddedControllerBridge::readFanCounters(uint64_t *output) {
    IOLockLock(lock);
    uint8_t firmware[MSIECPolicy::firmwareLength] {};
    auto result = readFirmware(firmware);
    const char expected[] = "15P2EMS1.110";
    for (uint32_t i = 0; result == kIOReturnSuccess && i < MSIECPolicy::firmwareLength; ++i)
        if (firmware[i] != static_cast<uint8_t>(expected[i])) result = kIOReturnUnsupported;
    uint8_t first[4] {}, second[4] {};
    for (uint32_t i = 0; result == kIOReturnSuccess && i < 4; ++i)
        result = read(static_cast<uint8_t>(0xC8 + i), &first[i]);
    for (uint32_t i = 0; result == kIOReturnSuccess && i < 4; ++i)
        result = read(static_cast<uint8_t>(0xC8 + i), &second[i]);
    for (uint32_t i = 0; result == kIOReturnSuccess && i < 4; ++i) {
        if (first[i] != second[i]) result = kIOReturnBusy;
        else output[i] = second[i];
    }
    IOLockUnlock(lock);
    return result;
}

IOReturn MSIEmbeddedControllerBridge::setLimit(uint64_t percent, uint64_t expected, uint64_t *before, uint64_t *after) {
    if (!MSIECPolicy::validPercent(percent) || !MSIECPolicy::validCurrent(expected)) return kIOReturnBadArgument;
    IOLockLock(lock);
    uint8_t firmware[MSIECPolicy::firmwareLength] {};
    auto result = readFirmware(firmware);
    if (result == kIOReturnSuccess && !MSIECPolicy::supportsCharge(firmware)) result = kIOReturnUnsupported;
    uint8_t current = 0;
    if (result == kIOReturnSuccess) result = read(MSIECPolicy::chargeAddress, &current);
    if (result == kIOReturnSuccess && current != expected) result = kIOReturnBusy;
    if (result == kIOReturnSuccess) {
        *before = current;
        IOACPIAddress location {};
        location.addr64 = MSIECPolicy::chargeAddress;
        const uint8_t encoded = MSIECPolicy::encode(static_cast<uint8_t>(percent));
        // Only this register and validated encoding can reach a hardware write.
        result = ec->writeAddressSpace(encoded, kIOACPIAddressSpaceIDEmbeddedController, location, 8, 0, 0);
        if (result == kIOReturnSuccess) result = read(MSIECPolicy::chargeAddress, &current);
        *after = current;
        if (result == kIOReturnSuccess && current != encoded) result = kIOReturnError;
    }
    // No speculative retry or rollback writes after a verification failure.
    IOLockUnlock(lock);
    return result;
}

IOReturn MSIEmbeddedControllerBridge::setFanMode(uint64_t mode, uint64_t expected, uint64_t *before, uint64_t *after) {
    if (!MSIECPolicy::validFanMode(mode) || !MSIECPolicy::validFanMode(expected)) return kIOReturnBadArgument;
    IOLockLock(lock);
    uint8_t firmware[MSIECPolicy::firmwareLength] {};
    auto result = readFirmware(firmware);
    if (result == kIOReturnSuccess && !MSIECPolicy::supportsCharge(firmware) && !MSIECPolicy::supportsFan(firmware)) result = kIOReturnUnsupported;
    uint8_t current = 0;
    if (result == kIOReturnSuccess) result = read(MSIECPolicy::fanModeAddress, &current);
    if (result == kIOReturnSuccess && current != expected) result = kIOReturnBusy;
    if (result == kIOReturnSuccess) {
        *before = current;
        IOACPIAddress location {};
        location.addr64 = MSIECPolicy::fanModeAddress;
        result = ec->writeAddressSpace(static_cast<uint8_t>(mode), kIOACPIAddressSpaceIDEmbeddedController, location, 8, 0, 0);
        if (result == kIOReturnSuccess) result = read(MSIECPolicy::fanModeAddress, &current);
        *after = current;
        if (result == kIOReturnSuccess && current != mode) result = kIOReturnError;
    }
    IOLockUnlock(lock);
    return result;
}

IOReturn MSIEmbeddedControllerBridge::setCoolerBoost(uint64_t enabled, uint64_t expected, uint64_t *before, uint64_t *after) {
    if (enabled > 1 || expected > 255) return kIOReturnBadArgument;
    IOLockLock(lock);
    uint8_t firmware[MSIECPolicy::firmwareLength] {};
    auto result = readFirmware(firmware);
    if (result == kIOReturnSuccess && !MSIECPolicy::supportsFan(firmware)) result = kIOReturnUnsupported;
    uint8_t current = 0;
    if (result == kIOReturnSuccess) result = read(MSIECPolicy::coolerBoostAddress, &current);
    if (result == kIOReturnSuccess && current != expected) result = kIOReturnBusy;
    if (result == kIOReturnSuccess) {
        *before = current;
        const uint8_t target = static_cast<uint8_t>((current & ~MSIECPolicy::coolerBoostBit) | (enabled ? MSIECPolicy::coolerBoostBit : 0));
        IOACPIAddress location {};
        location.addr64 = MSIECPolicy::coolerBoostAddress;
        result = ec->writeAddressSpace(target, kIOACPIAddressSpaceIDEmbeddedController, location, 8, 0, 0);
        if (result == kIOReturnSuccess) result = read(MSIECPolicy::coolerBoostAddress, &current);
        *after = current;
        if (result == kIOReturnSuccess && current != target) result = kIOReturnError;
    }
    IOLockUnlock(lock);
    return result;
}

// Request: fan index, six expected temperatures, six expected speeds, six desired speeds, expected mode.
// Receipt: six speed readbacks followed by mode readback; partial failures are never reported as success.
IOReturn MSIEmbeddedControllerBridge::setFanCurve(const uint8_t *request, uint8_t *receipt) {
    const uint8_t fan = request[0];
    if (fan > 1 || !MSIECPolicy::validFanMode(request[19])) return kIOReturnBadArgument;
    if (!MSIECPolicy::validCurveTemperatures(request+1)) return kIOReturnBadArgument;
    for (uint32_t i = 0; i < MSIECPolicy::curvePoints; ++i) {
        if (!MSIECPolicy::validCurveSpeed(request[7+i]) ||
            !MSIECPolicy::validDesiredCurveSpeed(request[13+i])) return kIOReturnBadArgument;
    }
    IOLockLock(lock);
    uint8_t firmware[MSIECPolicy::firmwareLength] {};
    auto result = readFirmware(firmware);
    if (result == kIOReturnSuccess && !MSIECPolicy::supportsFan(firmware)) result = kIOReturnUnsupported;
    uint8_t current = 0;
    const uint8_t temperatureBase = fan ? MSIECPolicy::curveGpuTemperature : MSIECPolicy::curveCpuTemperature;
    const uint8_t speedBase = fan ? MSIECPolicy::curveGpuSpeed : MSIECPolicy::curveCpuSpeed;
    if (result == kIOReturnSuccess) result = read(MSIECPolicy::fanModeAddress, &current);
    if (result == kIOReturnSuccess && current != request[19]) result = kIOReturnBusy;
    for (uint32_t i = 0; result == kIOReturnSuccess && i < MSIECPolicy::curvePoints; ++i) {
        result = read(static_cast<uint8_t>(temperatureBase+i), &current);
        if (result == kIOReturnSuccess && current != request[1+i]) result = kIOReturnBusy;
        if (result == kIOReturnSuccess) result = read(static_cast<uint8_t>(speedBase+i), &current);
        if (result == kIOReturnSuccess && current != request[7+i]) result = kIOReturnBusy;
    }
    for (uint32_t i = 0; result == kIOReturnSuccess && i < MSIECPolicy::curvePoints; ++i) {
        IOACPIAddress location {};
        location.addr64 = speedBase+i;
        if (request[7+i] != request[13+i])
            result = ec->writeAddressSpace(request[13+i], kIOACPIAddressSpaceIDEmbeddedController, location, 8, 0, 0);
        if (result == kIOReturnSuccess) result = read(static_cast<uint8_t>(speedBase+i), &current);
        receipt[i] = current;
        if (result == kIOReturnSuccess && current != request[13+i]) result = kIOReturnError;
    }
    if (result == kIOReturnSuccess && request[19] != 0x8D) {
        IOACPIAddress location {};
        location.addr64 = MSIECPolicy::fanModeAddress;
        result = ec->writeAddressSpace(0x8D, kIOACPIAddressSpaceIDEmbeddedController, location, 8, 0, 0);
        if (result == kIOReturnSuccess) result = read(MSIECPolicy::fanModeAddress, &current);
        receipt[6] = current;
        if (result == kIOReturnSuccess && current != 0x8D) result = kIOReturnError;
    }
    if (result == kIOReturnSuccess && request[19] == 0x8D) receipt[6] = 0x8D;
    IOLockUnlock(lock);
    return result;
}

// Selector 6: profile index, expected D2, expected D4 -> observed D2 and D4.
IOReturn MSIEmbeddedControllerBridge::setPerformance(const uint64_t *request, uint64_t *receipt) {
    if (request[0] > 2 || !MSIECPolicy::validShiftMode(request[1]) ||
        !MSIECPolicy::validFanMode(request[2]) ||
        !((request[1] == 0xC1 && (request[2] == 0x0D || request[2] == 0x1D)) ||
          (request[1] == 0xC4 && request[2] == 0x0D))) return kIOReturnBadArgument;
    const uint8_t shift = request[0] == 2 ? 0xC4 : 0xC1;
    const uint8_t fan = request[0] == 0 ? 0x1D : 0x0D;
    IOLockLock(lock);
    uint8_t firmware[MSIECPolicy::firmwareLength] {};
    auto result = readFirmware(firmware);
    if (result == kIOReturnSuccess && !MSIECPolicy::supportsFan(firmware)) result = kIOReturnUnsupported;
    uint8_t currentShift = 0, currentFan = 0;
    if (result == kIOReturnSuccess) result = read(MSIECPolicy::shiftModeAddress, &currentShift);
    if (result == kIOReturnSuccess) result = read(MSIECPolicy::fanModeAddress, &currentFan);
    if (result == kIOReturnSuccess && (currentShift != request[1] || currentFan != request[2]))
        result = kIOReturnBusy;
    if (result == kIOReturnSuccess && currentShift != shift) {
        IOACPIAddress location {};
        location.addr64 = MSIECPolicy::shiftModeAddress;
        result = ec->writeAddressSpace(shift, kIOACPIAddressSpaceIDEmbeddedController, location, 8, 0, 0);
        if (result == kIOReturnSuccess) result = read(MSIECPolicy::shiftModeAddress, &currentShift);
        if (result == kIOReturnSuccess && currentShift != shift) result = kIOReturnError;
    }
    if (result == kIOReturnSuccess && currentFan != fan) {
        IOACPIAddress location {};
        location.addr64 = MSIECPolicy::fanModeAddress;
        result = ec->writeAddressSpace(fan, kIOACPIAddressSpaceIDEmbeddedController, location, 8, 0, 0);
        if (result == kIOReturnSuccess) result = read(MSIECPolicy::fanModeAddress, &currentFan);
        if (result == kIOReturnSuccess && currentFan != fan) result = kIOReturnError;
    }
    receipt[0] = currentShift;
    receipt[1] = currentFan;
    IOLockUnlock(lock);
    return result;
}

IOReturn MSIEmbeddedControllerBridge::newUserClient(task_t task, void *securityID, UInt32 type,
                                                   OSDictionary *properties, IOUserClient **handler) {
    if (type != 0) return kIOReturnBadArgument;
    auto client = new MSIECUserClient;
    if (!client) return kIOReturnNoMemory;
    if (!client->initWithTask(task, securityID, type, properties)) { client->release(); return kIOReturnNotPermitted; }
    if (!client->attach(this)) { client->release(); return kIOReturnError; }
    if (!client->start(this)) { client->detach(this); client->release(); return kIOReturnError; }
    *handler = client;
    return kIOReturnSuccess;
}

bool MSIECUserClient::initWithTask(task_t task, void *securityID, UInt32 type, OSDictionary *properties) {
    const bool administrator = clientHasPrivilege(securityID, kIOClientPrivilegeAdministrator) == kIOReturnSuccess;
    if (!administrator && clientHasPrivilege(securityID, kIOClientPrivilegeLocalUser) != kIOReturnSuccess) return false;
    if (!IOUserClient::initWithTask(task, securityID, type, properties)) return false;
    setProperty("IOUserClientDefaultLocking", kOSBooleanTrue);
    return true;
}

bool MSIECUserClient::start(IOService *provider) {
    bridge = OSDynamicCast(MSIEmbeddedControllerBridge, provider);
    return bridge && IOUserClient::start(provider);
}

IOReturn MSIECUserClient::clientClose() { terminate(); return kIOReturnSuccess; }

IOReturn MSIEmbeddedControllerBridge::setMuteLED(uint64_t led, uint64_t enabled, uint64_t *output) {
    if (!MSIECPolicy::validMuteLED(led, enabled)) return kIOReturnBadArgument;
    IOLockLock(lock);
    uint8_t firmware[MSIECPolicy::firmwareLength] {};
    auto result = readFirmware(firmware);
    if (result == kIOReturnSuccess && !MSIECPolicy::supportsFan(firmware))
        result = kIOReturnUnsupported;
    const uint8_t address = MSIECPolicy::muteLEDAddress(led);
    uint8_t before = 0, after = 0;
    if (result == kIOReturnSuccess) result = read(address, &before);
    const uint8_t desired = MSIECPolicy::muteLEDValue(before, enabled != 0);
    if (result == kIOReturnSuccess && before != desired) {
        IOACPIAddress location {};
        location.addr64 = address;
        result = ec->writeAddressSpace(desired, kIOACPIAddressSpaceIDEmbeddedController, location, 8, 0, 0);
    }
    if (result == kIOReturnSuccess) result = read(address, &after);
    if (result == kIOReturnSuccess && after != desired) result = kIOReturnIOError;
    if (result == kIOReturnSuccess) *output = enabled;
    IOLockUnlock(lock);
    return result;
}

IOReturn MSIECUserClient::externalMethod(uint32_t selector, IOExternalMethodArguments *arguments,
                                        IOExternalMethodDispatch *, OSObject *, void *) {
    static const IOExternalMethodDispatch methods[] = {
        {firmwareCall, 0, 0, 0, MSIECPolicy::firmwareLength},
        {readCall, 1, 0, 1, 0},
        {limitCall, 2, 0, 2, 0},
        {fanModeCall, 2, 0, 2, 0},
        {coolerBoostCall, 2, 0, 2, 0},
        {fanCurveCall, 0, 20, 0, 7},
        {performanceCall, 3, 0, 2, 0},
        {frequencyCall, 0, 0, 2, 0},
        {fanCountersCall, 0, 0, 4, 0},
        {muteLEDCall, 2, 0, 1, 0},
        {touchpadCall, 1, 0, 1, 0}
    };
    if (selector >= 11 || !bridge || isInactive() || bridge->isInactive()) return kIOReturnUnsupported;
    // Only the two indicator bits are available to a local user, never arbitrary EC writes.
    if ((selector == 9 || selector == 10) &&
        clientHasPrivilege(current_task(), kIOClientPrivilegeLocalUser) != kIOReturnSuccess &&
        clientHasPrivilege(current_task(), kIOClientPrivilegeAdministrator) != kIOReturnSuccess)
        return kIOReturnNotPrivileged;
    // Recheck the caller on every write; transferring a connection must not transfer root authority.
    if (selector >= MSIECPolicy::setChargeLimit && selector <= MSIECPolicy::setPerformance &&
        clientHasPrivilege(current_task(), kIOClientPrivilegeAdministrator) != kIOReturnSuccess) return kIOReturnNotPrivileged;
    return IOUserClient::externalMethod(selector, arguments,
        const_cast<IOExternalMethodDispatch *>(&methods[selector]), this, nullptr);
}

IOReturn MSIECUserClient::touchpadCall(OSObject *, void *, IOExternalMethodArguments *arguments) {
    // VoodooI2CHID's existing keyboard-message protocol; no EC register writes.
    const uint64_t request = arguments->scalarInput[0];
    if (request > 2) return kIOReturnBadArgument; // 0/1 set, 2 query
    auto matching = IOService::serviceMatching("VoodooI2CPrecisionTouchpadHIDEventDriver");
    if (!matching) return kIOReturnNoMemory;
    auto iterator = IOService::getMatchingServices(matching);
    matching->release();
    if (!iterator) return kIOReturnNotFound;
    auto service = OSDynamicCast(IOService, iterator->getNextObject());
    if (!service) { iterator->release(); return kIOReturnNotFound; }
    if (iterator->getNextObject()) { iterator->release(); return kIOReturnUnsupported; }
    bool enabled = request == 1;
    IOReturn result = kIOReturnSuccess;
    if (request != 2)
        result = service->message(iokit_vendor_specific_msg(100), nullptr, &enabled);
    if (result == kIOReturnSuccess)
        result = service->message(iokit_vendor_specific_msg(101), nullptr, &enabled);
    if (result == kIOReturnSuccess && request != 2 && enabled != (request == 1))
        result = kIOReturnIOError;
    if (result == kIOReturnSuccess) arguments->scalarOutput[0] = enabled ? 1 : 0;
    iterator->release();
    return result;
}

IOReturn MSIECUserClient::firmwareCall(OSObject *target, void *, IOExternalMethodArguments *arguments) {
    auto client = static_cast<MSIECUserClient *>(target);
    return client->bridge->copyFirmware(static_cast<uint8_t *>(arguments->structureOutput));
}

IOReturn MSIECUserClient::muteLEDCall(OSObject *target, void *, IOExternalMethodArguments *arguments) {
    auto client = static_cast<MSIECUserClient *>(target);
    return client->bridge->setMuteLED(arguments->scalarInput[0], arguments->scalarInput[1],
                                    &arguments->scalarOutput[0]);
}

IOReturn MSIECUserClient::fanCountersCall(OSObject *target, void *, IOExternalMethodArguments *arguments) {
    auto client = static_cast<MSIECUserClient *>(target);
    return client->bridge->readFanCounters(arguments->scalarOutput);
}

IOReturn MSIECUserClient::frequencyCall(OSObject *, void *, IOExternalMethodArguments *arguments) {
    uint32_t a = 0, b = 0, c = 0, d = 0;
    __asm__ volatile("cpuid" : "=a"(a), "=b"(b), "=c"(c), "=d"(d) : "a"(0), "c"(0));
    if (b != 0x756e6547 || d != 0x49656e69 || c != 0x6c65746e) return kIOReturnUnsupported;
    __asm__ volatile("cpuid" : "=a"(a), "=b"(b), "=c"(c), "=d"(d) : "a"(1), "c"(0));
    const uint32_t family = (a >> 8) & 0xF;
    const uint32_t model = ((a >> 4) & 0xF) | ((a >> 12) & 0xF0);
    // Hardware CPUID avoids relying on the spoofed macOS CPU model.
    if (family != 6 || (model != 0xB7 && model != 0xBF)) return kIOReturnUnsupported;
    uint32_t lo = 0, hi = 0;
    if (rdmsr_carefully(0x198, &lo, &hi) != 0) return kIOReturnUnsupported;
    const uint32_t ratio = (lo >> 8) & 0xFF;
    if (ratio == 0 || ratio > 100) return kIOReturnNotReady;
    arguments->scalarOutput[0] = ratio * 100;
    arguments->scalarOutput[1] = (static_cast<uint64_t>(hi) << 32) | lo;
    return kIOReturnSuccess;
}
IOReturn MSIECUserClient::readCall(OSObject *target, void *, IOExternalMethodArguments *arguments) {
    auto client = static_cast<MSIECUserClient *>(target);
    return client->bridge->readRegister(arguments->scalarInput[0], &arguments->scalarOutput[0]);
}
IOReturn MSIECUserClient::limitCall(OSObject *target, void *, IOExternalMethodArguments *arguments) {
    auto client = static_cast<MSIECUserClient *>(target);
    return client->bridge->setLimit(arguments->scalarInput[0], arguments->scalarInput[1],
                                  &arguments->scalarOutput[0], &arguments->scalarOutput[1]);
}
IOReturn MSIECUserClient::fanModeCall(OSObject *target, void *, IOExternalMethodArguments *arguments) {
    auto client = static_cast<MSIECUserClient *>(target);
    return client->bridge->setFanMode(arguments->scalarInput[0], arguments->scalarInput[1],
                                      &arguments->scalarOutput[0], &arguments->scalarOutput[1]);
}
IOReturn MSIECUserClient::coolerBoostCall(OSObject *target, void *, IOExternalMethodArguments *arguments) {
    auto client = static_cast<MSIECUserClient *>(target);
    return client->bridge->setCoolerBoost(arguments->scalarInput[0], arguments->scalarInput[1],
                                          &arguments->scalarOutput[0], &arguments->scalarOutput[1]);
}
IOReturn MSIECUserClient::fanCurveCall(OSObject *target, void *, IOExternalMethodArguments *arguments) {
    auto client = static_cast<MSIECUserClient *>(target);
    return client->bridge->setFanCurve(static_cast<const uint8_t *>(arguments->structureInput),
                                       static_cast<uint8_t *>(arguments->structureOutput));
}
IOReturn MSIECUserClient::performanceCall(OSObject *target, void *, IOExternalMethodArguments *arguments) {
    auto client = static_cast<MSIECUserClient *>(target);
    return client->bridge->setPerformance(arguments->scalarInput, arguments->scalarOutput);
}
