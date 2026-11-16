#include "ECPolicy.hpp"
#include "CPUPowerSnapshot.hpp"
#include "CPUPowerPolicy.hpp"
#include "CoreCounters.hpp"
#include "IntelFrequency.hpp"
#include "CoreCounterCache.hpp"
#include "ProcessorBinding.hpp"
#include <IOKit/IOService.h>
#include <IOKit/IOUserClient.h>
#include <IOKit/IOLocks.h>
#include <IOKit/IOLib.h>
#include <IOKit/acpi/IOACPIPlatformDevice.h>
#include <libkern/c++/OSBoolean.h>
#include <libkern/c++/OSData.h>
#include <mach/kmod.h>
#include <i386/proc_reg.h>
#include <IOKit/IOMessage.h>
#include <IOKit/pwr_mgt/RootDomain.h>
#include <kern/clock.h>
#include <kern/thread_call.h>
#include <libkern/sysctl.h>

// XNU's fault-recovering helper returns nonzero on #GP; never use raw WRMSR.
extern "C" int wrmsr_carefully(uint32_t msr, uint64_t value);

static kern_return_t msiec_start(kmod_info *, void *) { return KMOD_RETURN_SUCCESS; }
static kern_return_t msiec_stop(kmod_info *, void *) { return KMOD_RETURN_SUCCESS; }
KMOD_EXPLICIT_DECL(org_shenying_msiecbridge, "0.4.9", msiec_start, msiec_stop)

class MSIEmbeddedControllerBridge : public IOService {
    OSDeclareDefaultStructors(MSIEmbeddedControllerBridge)
    friend class MSIECUserClient;
    IOLock *lock {nullptr};
    IOACPIPlatformDevice *ec {nullptr};
    IOSimpleLock *cpuLock {nullptr};
    IOLock *cacheLock {nullptr};
    CoreCounters::Cache counterCache {};
    ProcessorBinding::Callbacks binding {};
    thread_call_t samplerCall {nullptr};
    bool samplerRunning {false}, samplerStop {false}, samplerSleeping {false};
    unsigned samplerCount {0};
    uint64_t samplerLastSweep {0}, samplerGeneration {0};
    static void samplerEntry(void *, void *);
    void sampleProcessors();
    void stopSampler();
    IOReturn cachedCounter(unsigned, CoreCounters::Snapshot &);
    IONotifier *sleepNotifier {nullptr};
    uint64_t powerOriginal {0}, powerLast {0}, powerGeneration {1}, powerMode {5};
    uint8_t shiftOriginal {0}, fanOriginal {0}, shiftLast {0}, fanLast {0};
    bool powerCaptured {false}, powerOwned {false}, ecOwned {false};
    bool powerSleeping {false}, powerStale {false};
    bool lifecycleRestore {false};
    uint64_t powerOutcome {0};
    static IOReturn powerNotification(void *, void *, UInt32, IOService *, void *, vm_size_t);
    IOReturn readPackage(uint64_t *unit, uint64_t *value);
    IOReturn writePackage(uint64_t expected, uint64_t value, uint64_t *observed);
    IOReturn writePerformanceByte(uint8_t address, uint8_t value, uint8_t *observed);
    IOReturn read(uint8_t address, uint8_t *value);
    IOReturn readFirmware(uint8_t *bytes);
    IOReturn powerTransactionLocked(const uint64_t *, uint64_t *, bool);
    void restoreForLifecycle();
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
    IOReturn setCommonFeature(const uint64_t *request, uint64_t *receipt);
    IOReturn powerStatus(uint64_t *output);
    IOReturn powerTransaction(const uint64_t *request, uint64_t *output, bool sleepRestore = false);
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
    static IOReturn countersCall(OSObject *, void *, IOExternalMethodArguments *);
    static IOReturn cachedCountersCall(OSObject *, void *, IOExternalMethodArguments *);
    static IOReturn cpuPowerCall(OSObject *, void *, IOExternalMethodArguments *);
    static IOReturn powerStatusCall(OSObject *, void *, IOExternalMethodArguments *);
    static IOReturn powerTransactionCall(OSObject *, void *, IOExternalMethodArguments *);
    static IOReturn fanCountersCall(OSObject *, void *, IOExternalMethodArguments *);
    static IOReturn muteLEDCall(OSObject *, void *, IOExternalMethodArguments *);
    static IOReturn touchpadCall(OSObject *, void *, IOExternalMethodArguments *);
    static IOReturn commonFeatureCall(OSObject *, void *, IOExternalMethodArguments *);
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
    cpuLock = IOSimpleLockAlloc();
    if (!cpuLock) return false;
    cacheLock = IOLockAlloc();
    if (!cacheLock) return false;
    samplerCall = thread_call_allocate_with_priority(samplerEntry, this, THREAD_CALL_PRIORITY_LOW);
    if (!samplerCall) return false;
    sleepNotifier = registerPrioritySleepWakeInterest(powerNotification, this);
    if (!sleepNotifier) return false;
    setProperty("MSIECAPI", MSIECPolicy::apiVersion, 32);
    setProperty("MSIECDriverVersion", "0.4.9");
    setProperty("MSIECCounterProtocol", CoreCounters::version, 32);
    setProperty("MSIECCounterCache", CoreCounters::cacheVersion, 32);
    setProperty("MSIECStatus", "Ready; explicit user requests only");
    setProperty("MSIECProfile", "not-probed");
    setProperty("MSIECWriteEnabled", kOSBooleanFalse);
    // No ACPI evaluation, EC reads, timer, or writes during startup.
    registerService();
    return true;
}

void MSIEmbeddedControllerBridge::stop(IOService *provider) {
    if (sleepNotifier) { sleepNotifier->remove(); sleepNotifier = nullptr; }
    stopSampler();
    if (lock) {
        IOLockLock(lock);
        powerSleeping = true;
        restoreForLifecycle();
        ec = nullptr;
        IOLockUnlock(lock);
    }
    IOService::stop(provider);
}

void MSIEmbeddedControllerBridge::free() {
    stopSampler();
    if (cacheLock) { IOLockFree(cacheLock); cacheLock = nullptr; }
    if (cpuLock) { IOSimpleLockFree(cpuLock); cpuLock = nullptr; }
    if (lock) { IOLockFree(lock); lock = nullptr; }
    IOService::free();
}

IOReturn MSIEmbeddedControllerBridge::read(uint8_t address, uint8_t *value) {
    if (!ec || ((!lifecycleRestore) && (isInactive() || powerSleeping))) return kIOReturnNotReady;
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
    const auto *profile = MSIECProfiles::match(bytes);
    setProperty("MSIECProfile", profile ? profile->name : "unknown-read-only");
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
    const auto *profile = MSIECProfiles::match(firmware);
    const uint8_t address = profile ? profile->chargeAddress : 0;
    uint8_t current = 0;
    if (result == kIOReturnSuccess) result = read(address, &current);
    if (result == kIOReturnSuccess && !MSIECPolicy::validCurrent(current)) result = kIOReturnUnsupported;
    if (result == kIOReturnSuccess && current != expected) result = kIOReturnBusy;
    if (result == kIOReturnSuccess) {
        *before = current;
        IOACPIAddress location {};
        location.addr64 = address;
        const uint8_t encoded = MSIECPolicy::encode(static_cast<uint8_t>(percent));
        // Only this register and validated encoding can reach a hardware write.
        result = ec->writeAddressSpace(encoded, kIOACPIAddressSpaceIDEmbeddedController, location, 8, 0, 0);
        if (result == kIOReturnSuccess) result = read(address, &current);
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
    const auto *profile = MSIECProfiles::match(firmware);
    bool desiredValid = false, expectedValid = false;
    if (profile) for (unsigned i = 0; i < profile->modeCount; ++i) {
        desiredValid |= mode == profile->modes[i];
        expectedValid |= expected == profile->modes[i];
    }
    if (result == kIOReturnSuccess && (!profile || !desiredValid || !expectedValid)) result = kIOReturnUnsupported;
    const uint8_t address = profile ? profile->fanAddress : 0;
    uint8_t current = 0;
    if (result == kIOReturnSuccess) result = read(address, &current);
    if (result == kIOReturnSuccess && current != expected) result = kIOReturnBusy;
    if (result == kIOReturnSuccess) {
        *before = current;
        IOACPIAddress location {};
        location.addr64 = address;
        result = ec->writeAddressSpace(static_cast<uint8_t>(mode), kIOACPIAddressSpaceIDEmbeddedController, location, 8, 0, 0);
        if (result == kIOReturnSuccess) result = read(address, &current);
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
    if (result == kIOReturnSuccess && !MSIECProfiles::match(firmware)) result = kIOReturnUnsupported;
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

IOReturn MSIEmbeddedControllerBridge::setCommonFeature(const uint64_t *request, uint64_t *receipt) {
    if (request[0] > 3 || request[1] > 255 || request[2] > 255) return kIOReturnBadArgument;
    IOLockLock(lock);
    uint8_t firmware[MSIECPolicy::firmwareLength] {};
    auto result = readFirmware(firmware);
    const auto *profile = MSIECProfiles::match(firmware);
    uint8_t target = 0;
    if (result == kIOReturnSuccess &&
        (!profile || !MSIECPolicy::commonTarget(*profile, request[0], request[1], request[2], &target)))
        result = kIOReturnUnsupported;
    uint16_t address = 0x100;
    if (profile) {
        switch (request[0]) {
            case 0: address = profile->webcamAddress; break;
            case 1: address = profile->fnWinAddress; break;
            case 2: address = profile->shiftAddress; break;
            case 3: address = profile->fanAddress; break;
        }
    }
    uint8_t current = 0;
    if (result == kIOReturnSuccess) result = read(static_cast<uint8_t>(address), &current);
    if (result == kIOReturnSuccess && current != request[2]) result = kIOReturnBusy;
    if (result == kIOReturnSuccess && request[0] == 0 && request[1] == 1 &&
        profile->webcamBlockAddress <= 255) {
        uint8_t block = 0;
        result = read(static_cast<uint8_t>(profile->webcamBlockAddress), &block);
        if (result == kIOReturnSuccess && !(block & (1U << profile->webcamBit)))
            result = kIOReturnNotPermitted;
    }
    receipt[0] = current;
    if (result == kIOReturnSuccess && current != target) {
        IOACPIAddress location {};
        location.addr64 = address;
        result = ec->writeAddressSpace(target, kIOACPIAddressSpaceIDEmbeddedController, location, 8, 0, 0);
    }
    if (result == kIOReturnSuccess) result = read(static_cast<uint8_t>(address), &current);
    receipt[1] = current;
    if (result == kIOReturnSuccess && current != target) result = kIOReturnIOError;
    IOLockUnlock(lock);
    return result;
}

IOReturn MSIECUserClient::commonFeatureCall(OSObject *target, void *, IOExternalMethodArguments *arguments) {
    auto client = static_cast<MSIECUserClient *>(target);
    return client->bridge->setCommonFeature(arguments->scalarInput, arguments->scalarOutput);
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
        {touchpadCall, 1, 0, 1, 0},
        {commonFeatureCall, 3, 0, 2, 0},
        {cpuPowerCall, 0, 0, CPUPowerSnapshot::count, 0},
        {powerStatusCall, 0, 0, CPUPowerPolicy::statusCount, 0},
        {powerTransactionCall, 6, 0, 4, 0},
        {nullptr, 0, 0, 0, 0}, // Retired large-buffer protocol.
        {countersCall, 0, 0, 0, sizeof(CoreCounters::Snapshot)},
        {cachedCountersCall, 1, 0, 0, sizeof(CoreCounters::Snapshot)}
    };
    if (selector >= 18 || selector == 15 || !bridge || isInactive() || bridge->isInactive()) return kIOReturnUnsupported;
    // Only the two indicator bits are available to a local user, never arbitrary EC writes.
    if ((selector == 9 || selector == 10) &&
        clientHasPrivilege(current_task(), kIOClientPrivilegeLocalUser) != kIOReturnSuccess &&
        clientHasPrivilege(current_task(), kIOClientPrivilegeAdministrator) != kIOReturnSuccess)
        return kIOReturnNotPrivileged;
    // Recheck the caller on every write; transferring a connection must not transfer root authority.
    if (((selector >= MSIECPolicy::setChargeLimit && selector <= MSIECPolicy::setPerformance) || selector == 11 || selector == 14) &&
        clientHasPrivilege(current_task(), kIOClientPrivilegeAdministrator) != kIOReturnSuccess) return kIOReturnNotPrivileged;
    const bool directHardware = selector == 7 || selector == 10 || selector == 12 || selector == 16;
    if (directHardware) {
        IOLockLock(bridge->lock);
        if (bridge->powerSleeping || !bridge->ec) {
            IOLockUnlock(bridge->lock);
            return kIOReturnNotReady;
        }
    }
    const auto result = IOUserClient::externalMethod(selector, arguments,
        const_cast<IOExternalMethodDispatch *>(&methods[selector]), this, nullptr);
    if (directHardware) IOLockUnlock(bridge->lock);
    return result;
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

IOReturn MSIECUserClient::cpuPowerCall(OSObject *, void *, IOExternalMethodArguments *arguments) {
    auto out = arguments->scalarOutput;
    bzero(out, CPUPowerSnapshot::count * sizeof(uint64_t));
    out[0] = CPUPowerSnapshot::version;
    // Pin the short snapshot to the current logical processor, never rendezvous or write MSRs.
    auto sampleLock = IOSimpleLockAlloc();
    if (!sampleLock) return kIOReturnNoMemory;
    IOSimpleLockLock(sampleLock);
    auto cpuid = [](uint32_t leaf, uint32_t sub, uint32_t &a, uint32_t &b, uint32_t &c, uint32_t &d) {
        __asm__ volatile("cpuid" : "=a"(a), "=b"(b), "=c"(c), "=d"(d) : "a"(leaf), "c"(sub));
    };
    uint32_t a, b, c, d;
    cpuid(0, 0, a, b, c, d);
    out[2] = b; out[3] = d; out[4] = c; out[5] = a;
    const bool intel = b == 0x756e6547 && d == 0x49656e69 && c == 0x6c65746e;
    cpuid(0x80000000, 0, a, b, c, d); out[14] = a;
    if (intel && out[5] >= 1) {
        cpuid(1, 0, a, b, c, d); out[6] = a;
        const bool hasMSR = d & (1U << 5);
        out[8] = b >> 24;
        if (out[5] >= 0xB) {
            cpuid(0xB, 0, a, b, c, d);
            if (b) { out[8] = d; out[1] |= 1ULL << 8; }
        }
        if (out[5] >= 6) { cpuid(6, 0, a, b, c, d); out[7] = a; }
        auto readField = [&](unsigned field, uint32_t msr) {
            uint32_t lo = 0, hi = 0;
            if (rdmsr_carefully(msr, &lo, &hi) == 0) {
                out[field] = (static_cast<uint64_t>(hi) << 32) | lo;
                out[1] |= 1ULL << field;
            }
        };
        if (hasMSR && (out[7] & (1U << 7))) {
            readField(9, 0x770);
            if ((out[1] & (1ULL << 9)) && (out[9] & 1)) {
                readField(10, 0x771);
                readField(11, 0x774);
            }
        }
        const uint32_t signature = static_cast<uint32_t>(out[6]);
        const uint32_t baseFamily = (signature >> 8) & 15;
        const uint32_t family = baseFamily == 15 ? baseFamily + ((signature >> 20) & 255) : baseFamily;
        const uint32_t model = ((signature >> 4) & 15) |
            ((baseFamily == 6 || baseFamily == 15) ? ((signature >> 12) & 0xF0) : 0);
        if (hasMSR && CPUPowerSnapshot::supportsPackagePower(family, model)) {
            readField(12, 0x606);
            readField(13, 0x610);
        }
    }
    IOSimpleLockUnlock(sampleLock);
    IOSimpleLockFree(sampleLock);
    return kIOReturnSuccess;
}

IOReturn MSIEmbeddedControllerBridge::readPackage(uint64_t *unit, uint64_t *value) {
    auto cpuid = [](uint32_t leaf, uint32_t &a, uint32_t &b, uint32_t &c, uint32_t &d) {
        __asm__ volatile("cpuid" : "=a"(a), "=b"(b), "=c"(c), "=d"(d) : "a"(leaf), "c"(0));
    };
    IOSimpleLockLock(cpuLock);
    uint32_t a, b, c, d;
    cpuid(0, a, b, c, d);
    bool supported = a >= 1 && b == 0x756e6547 && d == 0x49656e69 && c == 0x6c65746e;
    cpuid(1, a, b, c, d);
    supported &= ((a >> 8) & 15) == 6 &&
        ((((a >> 4) & 15) | ((a >> 12) & 0xF0)) == 0xB7) && (d & (1U << 5));
    cpuid(0x80000000, a, b, c, d);
    supported &= a >= 0x80000004;
    char brand[49] {};
    for (uint32_t leaf = 0; supported && leaf < 3; ++leaf) {
        cpuid(0x80000002 + leaf, a, b, c, d);
        const uint32_t words[] = {a,b,c,d};
        bcopy(words, brand + leaf * 16, 16);
    }
    // Model B7 includes several SKUs; only the measured 14700HX is write-enabled.
    bool sku = false;
    const char expected[] = "i7-14700HX";
    for (unsigned i = 0; i + sizeof(expected) - 1 <= 48; ++i) {
        bool match = true;
        for (unsigned j = 0; j < sizeof(expected) - 1; ++j) match &= brand[i+j] == expected[j];
        sku |= match;
    }
    uint32_t lo = 0, hi = 0;
    IOReturn result = kIOReturnUnsupported;
    if (supported && sku && rdmsr_carefully(0x606, &lo, &hi) == 0) {
        *unit = (static_cast<uint64_t>(hi) << 32) | lo;
        if (rdmsr_carefully(0x610, &lo, &hi) == 0) {
            *value = (static_cast<uint64_t>(hi) << 32) | lo;
            result = kIOReturnSuccess;
        }
    }
    IOSimpleLockUnlock(cpuLock);
    return result;
}

IOReturn MSIEmbeddedControllerBridge::writePackage(uint64_t expected, uint64_t value, uint64_t *observed) {
    IOSimpleLockLock(cpuLock);
    uint32_t lo = 0, hi = 0;
    if (rdmsr_carefully(0x610, &lo, &hi) != 0 ||
        ((static_cast<uint64_t>(hi) << 32) | lo) != expected) {
        IOSimpleLockUnlock(cpuLock);
        return kIOReturnBusy;
    }
    const int written = wrmsr_carefully(0x610, value);
    const int readback = rdmsr_carefully(0x610, &lo, &hi);
    IOSimpleLockUnlock(cpuLock);
    if (readback == 0) *observed = (static_cast<uint64_t>(hi) << 32) | lo;
    return written == 0 && readback == 0 && *observed == value ? kIOReturnSuccess : kIOReturnIOError;
}

IOReturn MSIEmbeddedControllerBridge::writePerformanceByte(uint8_t address, uint8_t value, uint8_t *observed) {
    IOACPIAddress location {};
    location.addr64 = address;
    auto result = ec->writeAddressSpace(value, kIOACPIAddressSpaceIDEmbeddedController, location, 8, 0, 0);
    const auto readback = read(address, observed);
    return result == kIOReturnSuccess && readback == kIOReturnSuccess && *observed == value
        ? kIOReturnSuccess : kIOReturnIOError;
}

// Status v1: version, flags, generation, unit, current, original, last, mode,
// shift, fan, original shift, original fan, outcome, reserved.
IOReturn MSIEmbeddedControllerBridge::powerStatus(uint64_t *out) {
    bzero(out, CPUPowerPolicy::statusCount * sizeof(uint64_t));
    IOLockLock(lock);
    out[0] = 1;
    out[2] = powerGeneration;
    out[5] = powerOriginal; out[6] = powerLast; out[7] = powerMode;
    out[10] = shiftOriginal; out[11] = fanOriginal; out[12] = powerOutcome;
    uint64_t unit = 0, current = 0;
    uint8_t firmware[MSIECPolicy::firmwareLength] {}, shift = 0, fan = 0;
    const bool ready = !powerSleeping && readPackage(&unit, &current) == kIOReturnSuccess &&
        readFirmware(firmware) == kIOReturnSuccess && MSIECPolicy::supportsFan(firmware) &&
        read(0xD2, &shift) == kIOReturnSuccess && read(0xD4, &fan) == kIOReturnSuccess;
    const bool validEC = (shift == 0xC1 || shift == 0xC2 || shift == 0xC4) &&
        MSIECPolicy::validFanMode(fan);
    if (ready && ((powerOwned && !CPUPowerPolicy::owns(current, powerLast)) ||
                  (ecOwned && (shift != shiftLast || fan != fanLast)))) {
        powerStale = true;
        powerMode = 5;
        powerOutcome = 2;
    }
    out[1] = (ready && validEC && CPUPowerPolicy::validBaseline(current) ? 1 : 0) |
        (powerCaptured ? 2 : 0) | (powerOwned ? 4 : 0) | (ecOwned ? 8 : 0) |
        (powerStale ? 16 : 0) | (powerSleeping ? 32 : 0);
    out[3] = unit; out[4] = current; out[7] = powerMode;
    out[8] = shift; out[9] = fan; out[12] = powerOutcome;
    IOLockUnlock(lock);
    return kIOReturnSuccess;
}

// Request: mode (0...4, 5 restore), use eco, expected generation/MSR/shift/fan.
// Receipt: outcome (0 verified, 1 rolled back, 2 conflict, 3 uncertain), MSR, shift, fan.
IOReturn MSIEmbeddedControllerBridge::powerTransaction(const uint64_t *in, uint64_t *out, bool sleepRestore) {
    if (in[0] > 5 || in[1] > 1 || (in[1] && in[0] != 0)) return kIOReturnBadArgument;
    IOLockLock(lock);
    const auto result = powerTransactionLocked(in, out, sleepRestore);
    IOLockUnlock(lock);
    return result;
}

IOReturn MSIEmbeddedControllerBridge::powerTransactionLocked(const uint64_t *in, uint64_t *out, bool sleepRestore) {
    uint64_t unit = 0, current = 0;
    uint8_t firmware[MSIECPolicy::firmwareLength] {}, shift = 0, fan = 0;
    auto result = powerSleeping && !sleepRestore ? kIOReturnNotReady : readPackage(&unit, &current);
    if (result == kIOReturnSuccess) result = readFirmware(firmware);
    if (result == kIOReturnSuccess && !MSIECPolicy::supportsFan(firmware)) result = kIOReturnUnsupported;
    if (result == kIOReturnSuccess) result = read(0xD2, &shift);
    if (result == kIOReturnSuccess) result = read(0xD4, &fan);
    if (result == kIOReturnSuccess && !sleepRestore && (in[2] != powerGeneration || in[3] != current ||
        in[4] != shift || in[5] != fan)) result = kIOReturnBusy;
    if (result == kIOReturnSuccess && (!CPUPowerPolicy::validBaseline(current) ||
        (shift != 0xC1 && shift != 0xC2 && shift != 0xC4) ||
        !MSIECPolicy::validFanMode(fan))) result = kIOReturnUnsupported;
    if (result == kIOReturnSuccess && in[0] != 5 && (powerStale ||
        (powerOwned && !CPUPowerPolicy::owns(current, powerLast)) ||
        (ecOwned && (shift != shiftLast || fan != fanLast)))) result = kIOReturnBusy;
    if (result != kIOReturnSuccess) return result;
    const bool restore = in[0] == 5, eco = in[0] == 0 && in[1];
    if (!powerCaptured && !restore) {
        powerOriginal = current; shiftOriginal = shift; fanOriginal = fan;
        powerCaptured = true;
    }
    uint64_t target = current;
    uint8_t targetShift = shift, targetFan = fan;
    if (restore || eco) {
        if (restore)
            target = CPUPowerPolicy::restoreOwnedPackage(powerOwned, powerOriginal, current, powerLast);
        else if (powerOwned)
            target = CPUPowerPolicy::restored(powerOriginal, current);
        if (restore && ecOwned) {
            targetShift = CPUPowerPolicy::restoreOwnedByte(ecOwned, shiftOriginal, shift, shiftLast);
            targetFan = CPUPowerPolicy::restoreOwnedByte(ecOwned, fanOriginal, fan, fanLast);
        }
        if (eco) { targetShift = 0xC2; targetFan = 0x0D; }
    } else {
        if (!CPUPowerPolicy::target(powerOriginal, current, unit, static_cast<unsigned>(in[0]), &target)) {
            return kIOReturnUnsupported;
        }
        targetShift = in[0] >= 3 ? 0xC4 : 0xC1;
        targetFan = in[0] == 1 ? 0x1D : 0x0D;
    }
    const uint64_t before = current;
    const uint8_t beforeShift = shift, beforeFan = fan;
    bool attemptedPower = false, attemptedShift = false, attemptedFan = false;
    // Set package budget before fan quieting/eco. EC writes may overwrite it:
    // verify again afterwards instead of repeatedly fighting firmware.
    if (target != current) {
        attemptedPower = true;
        result = writePackage(current, target, &current);
    }
    if (result == kIOReturnSuccess && targetShift != shift) {
        attemptedShift = true;
        result = writePerformanceByte(0xD2, targetShift, &shift);
    }
    if (result == kIOReturnSuccess && targetFan != fan) {
        attemptedFan = true;
        result = writePerformanceByte(0xD4, targetFan, &fan);
    }
    if (result == kIOReturnSuccess) result = readPackage(&unit, &current);
    if (result == kIOReturnSuccess) result = read(0xD2, &shift);
    if (result == kIOReturnSuccess) result = read(0xD4, &fan);
    if (result == kIOReturnSuccess && (current != target || shift != targetShift || fan != targetFan))
        result = kIOReturnIOError;
    if (result == kIOReturnSuccess) {
        powerLast = current; shiftLast = shift; fanLast = fan;
        powerOwned = powerCaptured && !CPUPowerPolicy::owns(current, powerOriginal);
        ecOwned = powerCaptured && (shift != shiftOriginal || fan != fanOriginal);
        powerMode = restore ? 5 : in[0];
        powerStale = false;
        powerOutcome = 0;
        if (restore) {
            powerOwned = false;
            ecOwned = false;
            powerCaptured = false;
        }
    } else {
        // Conditional rollback only: never overwrite a value not matching our write.
        bool recovered = true;
        uint8_t observed = 0;
        if (attemptedFan) {
            if (read(0xD4, &observed) != kIOReturnSuccess) recovered = false;
            else if (observed == targetFan)
                recovered &= writePerformanceByte(0xD4, beforeFan, &observed) == kIOReturnSuccess;
            else recovered &= observed == beforeFan;
        }
        if (attemptedShift) {
            if (read(0xD2, &observed) != kIOReturnSuccess) recovered = false;
            else if (observed == targetShift)
                recovered &= writePerformanceByte(0xD2, beforeShift, &observed) == kIOReturnSuccess;
            else recovered &= observed == beforeShift;
        }
        if (attemptedPower) {
            if (readPackage(&unit, &current) != kIOReturnSuccess) recovered = false;
            else if (CPUPowerPolicy::owns(current, target))
                recovered &= writePackage(current, CPUPowerPolicy::restored(before, current), &current) == kIOReturnSuccess;
            else recovered &= CPUPowerPolicy::owns(current, before);
        }
        recovered &= readPackage(&unit, &current) == kIOReturnSuccess &&
            CPUPowerPolicy::owns(current, before) &&
            read(0xD2, &shift) == kIOReturnSuccess && shift == beforeShift &&
            read(0xD4, &fan) == kIOReturnSuccess && fan == beforeFan;
        powerOutcome = recovered ? 1 : 3;
        if (!recovered) { powerStale = true; powerMode = 5; }
    }
    ++powerGeneration;
    out[0] = powerOutcome; out[1] = current; out[2] = shift; out[3] = fan;
    return kIOReturnSuccess;
}

// Caller holds lock; external readers cannot enter during conditional restoration.
void MSIEmbeddedControllerBridge::restoreForLifecycle() {
    if (!powerOwned && !ecOwned) return;
    lifecycleRestore = true;
    const uint64_t input[] = {5, 0, 0, 0, 0, 0};
    uint64_t output[4] {};
    const auto result = powerTransactionLocked(input, output, true);
    lifecycleRestore = false;
    if (result != kIOReturnSuccess || output[0] != 0) {
        powerStale = true;
        powerOutcome = 3;
    }
}

IOReturn MSIEmbeddedControllerBridge::powerNotification(void *target, void *, UInt32 message,
                                                        IOService *, void *argument, vm_size_t) {
    auto bridge = static_cast<MSIEmbeddedControllerBridge *>(target);
    if (message == kIOMessageSystemWillSleep) {
        IOLockLock(bridge->cacheLock);
        bridge->samplerSleeping = true;
        ++bridge->samplerGeneration;
        bridge->counterCache.clear();
        IOLockUnlock(bridge->cacheLock);
        thread_call_cancel_wait(bridge->samplerCall);
        IOLockLock(bridge->cacheLock);
        bridge->samplerRunning = false;
        IOLockUnlock(bridge->cacheLock);
        IOLockLock(bridge->lock);
        bridge->powerSleeping = true;
        bridge->restoreForLifecycle();
        ++bridge->powerGeneration;
        IOLockUnlock(bridge->lock);
        acknowledgeSleepWakeNotification(argument);
    } else if (message == kIOMessageSystemHasPoweredOn) {
        IOLockLock(bridge->cacheLock);
        bridge->samplerSleeping = false;
        ++bridge->samplerGeneration;
        bridge->counterCache.clear();
        IOLockUnlock(bridge->cacheLock);
        IOLockLock(bridge->lock);
        bridge->powerSleeping = false;
        bridge->powerMode = 5;
        if (!bridge->powerOwned && !bridge->ecOwned) {
            // Firmware may establish different limits on wake; capture afresh
            // only on the next explicit apply, never automatically reapply.
            bridge->powerCaptured = false;
            bridge->powerStale = false;
        }
        ++bridge->powerGeneration;
        IOLockUnlock(bridge->lock);
    }
    return kIOReturnSuccess;
}

IOReturn MSIECUserClient::powerStatusCall(OSObject *target, void *, IOExternalMethodArguments *args) {
    return static_cast<MSIECUserClient *>(target)->bridge->powerStatus(args->scalarOutput);
}
IOReturn MSIECUserClient::powerTransactionCall(OSObject *target, void *, IOExternalMethodArguments *args) {
    return static_cast<MSIECUserClient *>(target)->bridge->powerTransaction(args->scalarInput, args->scalarOutput);
}

extern "C" int cpu_number(void);

static void collectCoreCounters(void *context) {
    auto snapshot = static_cast<CoreCounters::Snapshot *>(context);
    snapshot->count = 1;
    const int localCPU = cpu_number();
    if (localCPU >= 0 && localCPU < 4096)
        snapshot->logicalCPUPlusOne = static_cast<uint64_t>(localCPU) + 1;
    auto &record = snapshot->cores[0];
    auto cpuid = [&](uint32_t leaf, uint32_t sub) {
        IntelFrequency::Registers r {};
        __asm__ volatile("cpuid" : "=a"(r.a), "=b"(r.b), "=c"(r.c), "=d"(r.d) : "a"(leaf), "c"(sub));
        return r;
    };
    auto readMSR = [](uint32_t address, uint64_t &value) {
        uint32_t lo = 0, hi = 0;
        if (rdmsr_carefully(address, &lo, &hi)) return false;
        value = (uint64_t(hi) << 32) | lo;
        return true;
    };
    auto readTime = []() {
        uint64_t uptime = 0, nanoseconds = 0;
        clock_get_uptime(&uptime);
        absolutetime_to_nanoseconds(uptime, &nanoseconds);
        return nanoseconds;
    };
    IntelFrequency::collect(record, cpuid, readMSR, readTime);
}

static uint64_t counterTime() {
    uint64_t uptime = 0, nanoseconds = 0;
    clock_get_uptime(&uptime);
    absolutetime_to_nanoseconds(uptime, &nanoseconds);
    return nanoseconds;
}

void MSIEmbeddedControllerBridge::samplerEntry(void *context, void *) {
    static_cast<MSIEmbeddedControllerBridge *>(context)->sampleProcessors();
}

void MSIEmbeddedControllerBridge::stopSampler() {
    if (!cacheLock) return;
    IOLockLock(cacheLock);
    samplerStop = true;
    IOLockUnlock(cacheLock);
    if (samplerCall) {
        thread_call_cancel_wait(samplerCall);
        thread_call_free(samplerCall);
        samplerCall = nullptr;
    }
}

void MSIEmbeddedControllerBridge::sampleProcessors() {
    IOLockLock(cacheLock);
    if (!samplerStop && !samplerSleeping) {
        const auto generation = samplerGeneration;
        const auto count = samplerCount;
        IOLockUnlock(cacheLock);
        for (unsigned index = 0; index < count; ++index) {
            IOLockLock(cacheLock);
            const bool cancel = samplerStop || samplerSleeping || generation != samplerGeneration;
            IOLockUnlock(cacheLock);
            if (cancel) break;
            // Restore the callout thread's binding before returning it to the pool.
            if (!ProcessorBinding::schedulable(binding.logicalCPU(static_cast<int>(index)), index)) continue;
            auto processor = binding.processor(static_cast<int>(index));
            if (!processor) continue;
            auto previous = binding.bind(processor);
            IOSleep(1);
            CoreCounters::Snapshot snapshot {};
            snapshot.version = CoreCounters::version;
            IOSimpleLockLock(cpuLock);
            collectCoreCounters(&snapshot);
            IOSimpleLockUnlock(cpuLock);
            binding.bind(previous);
            IOLockLock(cacheLock);
            if (!samplerStop && !samplerSleeping && generation == samplerGeneration)
                counterCache.publish(index, snapshot);
            IOLockUnlock(cacheLock);
        }
        IOLockLock(cacheLock);
    }
    samplerRunning = false;
    samplerLastSweep = counterTime();
    IOLockUnlock(cacheLock);
}

IOReturn MSIEmbeddedControllerBridge::cachedCounter(unsigned index, CoreCounters::Snapshot &snapshot) {
    if (index >= CoreCounters::cacheCapacity) return kIOReturnBadArgument;
    IOLockLock(cacheLock);
    if (samplerStop || samplerSleeping) {
        IOLockUnlock(cacheLock);
        return kIOReturnNotReady;
    }
    if (!samplerCount) {
        // Fail closed outside the ABI verified for this candidate.
        int count = 0;
        size_t size = sizeof(count);
        if (!ProcessorBinding::supportedKernel(version_major, version_minor) ||
            sysctlbyname("hw.ncpu", &count, &size, nullptr, 0) || size != sizeof(count) ||
            count <= 0 || count > static_cast<int>(CoreCounters::cacheCapacity)) {
            IOLockUnlock(cacheLock);
            return kIOReturnUnsupported;
        }
        pmKextRegister(102, nullptr, &binding);
        if (!binding.logicalCPU || !binding.processor || !binding.bind) {
            IOLockUnlock(cacheLock);
            return kIOReturnUnsupported;
        }
        samplerCount = static_cast<unsigned>(count);
    }
    if (index >= samplerCount) {
        IOLockUnlock(cacheLock);
        return kIOReturnBadArgument;
    }
    const auto now = counterTime();
    if (!samplerRunning) {
        samplerRunning = true;
        uint64_t deadline = 0;
        const auto elapsed = now >= samplerLastSweep ? now - samplerLastSweep : 0;
        const auto delay = elapsed >= 500000000ULL ? 0 : 500000000ULL - elapsed;
        clock_interval_to_deadline(static_cast<uint32_t>(delay / 1000000 + 1), kMillisecondScale, &deadline);
        thread_call_enter_delayed(samplerCall, deadline);
    }
    snapshot = counterCache.read(index, now, samplerGeneration);
    IOLockUnlock(cacheLock);
    return kIOReturnSuccess;
}

IOReturn MSIECUserClient::cachedCountersCall(OSObject *target, void *, IOExternalMethodArguments *args) {
    if (!CoreCounters::acceptsInlineOutput(args->structureOutputDescriptor != nullptr,
            args->structureOutput, args->structureOutputSize) ||
            args->scalarInput[0] >= CoreCounters::cacheCapacity) return kIOReturnBadArgument;
    CoreCounters::Snapshot snapshot {};
    auto client = static_cast<MSIECUserClient *>(target);
    const auto result = client->bridge->cachedCounter(static_cast<unsigned>(args->scalarInput[0]), snapshot);
    if (result != kIOReturnSuccess) return result;
    bcopy(&snapshot, args->structureOutput, sizeof(snapshot));
    args->structureOutputSize = sizeof(snapshot);
    return kIOReturnSuccess;
}

IOReturn MSIECUserClient::countersCall(OSObject *target, void *, IOExternalMethodArguments *arguments) {
    const auto size = sizeof(CoreCounters::Snapshot);
    // Descriptor-backed output is deliberately unsupported, including oversized callers.
    if (!CoreCounters::acceptsInlineOutput(arguments->structureOutputDescriptor != nullptr,
            arguments->structureOutput, arguments->structureOutputSize)) {
        return kIOReturnBadArgument;
    }
    CoreCounters::Snapshot snapshot {};
    snapshot.version = CoreCounters::version;
    auto client = static_cast<MSIECUserClient *>(target);
    // Pin only this thread's short read. Never wait for another processor.
    IOSimpleLockLock(client->bridge->cpuLock);
    collectCoreCounters(&snapshot);
    IOSimpleLockUnlock(client->bridge->cpuLock);
    bcopy(&snapshot, arguments->structureOutput, size);
    arguments->structureOutputSize = static_cast<uint32_t>(size);
    return kIOReturnSuccess;
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
