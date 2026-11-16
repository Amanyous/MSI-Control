# MSIECBridge 0.2.1

## CPU details roster (0.4.8 / API 15 / protocol 4)

Protocol 4 retains the 96-byte inline response and uses header word 3 for
`cpu_number() + 1`, obtained under the same short local lock as the counters.
The x86_64 kernel export belongs to `com.apple.kpi.unsupported`; this dependency
is explicit. No cross-core rendezvous, CPU targeting or counter writes are added.
The application lists all OS logical processor numbers inside CPU details,
retains observed APIC/type identity and shows waiting states for unobserved or
expired frequencies. Scheduler coverage of every processor is not guaranteed.
Protocols 2/3 still support aggregate readings but have no OS processor identity
and are never guessed into the numbered details rows.

## Frequency compatibility candidate (0.4.7 / API 15 / protocol 3)

Frequency reads now detect Intel family 6 hardware capabilities rather than
requiring Raptor Lake model IDs. APERF/MPERF support and a reliable base clock
remain mandatory. Non-hybrid CPUs are reported as ordinary cores (type 0);
hybrid CPUs retain CPUID P/E identification.

Protocol 3 retains the 96-byte inline response. Its `tsc` field contains OS
monotonic nanoseconds and `tscHz` is 1 GHz, so interval timing does not require
CPUID leaf 0x15. Base frequency uses leaf 0x16 when available. For mainstream
Sandy Bridge, Ivy Bridge, Haswell, Broadwell, Skylake, Kaby/Coffee Lake,
Comet Lake, Ice Lake, Tiger Lake and Rocket Lake client model IDs listed in
`IntelFrequency.hpp`, a missing base clock can fall back to a guarded read of
MSR_PLATFORM_INFO's non-turbo ratio with a 100 MHz reference. Other models
without a CPUID base clock are rejected; Atom, HEDT/Xeon and first-generation
Core are not covered by that fallback.

This is local-only sampling, not a complete all-core scan. There are no
cross-CPU calls, calibration waits, or sampling MSR writes. CPU power-control
support is unchanged. Older-hardware compatibility is not physically verified.
The updated application accepts protocols 2 and 3; older applications that
only accept protocol 2 require an app update before using this candidate.

Intel macOS 14+ experimental IOKit Kext, API version 1. Attaches as a client of AppleACPIEC using a separate IOMatchCategory. It publishes readiness at startup without evaluating ACPI methods or reading/writing EC. No polling timer, direct port I/O, startup probe, automatic writes, or persistent helper.

The service obtains AppleACPIEC's IOACPIPlatformDevice provider and uses the system EmbeddedController address-space API for 8-bit operations. Target compatibility is unverified: successful compilation does not establish that this address-space path works on the intended firmware.

## Build

```sh
python3 Drivers/MSIECBridge/build.py
```

Requires macOS Command Line Tools with SDK Kernel.framework headers. Produces x86_64 Kext under `work/driver-build/` and copies it into the app's source resources. It does not load, sign or install the Kext. Release packaging signs the helper, Kext and app; the explicit OpenCore installer signs and verifies the selected destination copy.

## User client protocol

Service class: `MSIEmbeddedControllerBridge`, connection type 0, registry `MSIECAPI = 2`. Local console users and root may open; the current caller must be root for every write. Passing an already-open connection to another process does not grant write authority.

| Selector | Input | Output | Operation |
| --- | --- | --- | --- |
| 0 | none | 12-byte structure | Read firmware at A0–AB |
| 1 | one uint64 address (0–255) | one uint64 byte | Read a single EC byte |
| 2 | two uint64: percent, expected old byte | two uint64: before, after | Validated D7 charge-limit transaction |
| 3 | two uint64: mode byte, expected old D4 byte | two uint64: before, after | Validated D4 fan mode transaction |

IOUserClient validates exact argument counts and structure sizes. A bridge-wide lock serializes full operations across clients, including write validation and readback. Selector 2 re-reads firmware and permits `15P2EMS1.110`, `15P4EMS1.105`, or `15P4EMS1.107`; percent must be 10–100, expected byte must decode as a valid current threshold or 0x80 (unknown). If actual D7 differs from expected, it returns `kIOReturnBusy` without writing. It writes `percent | 0x80` to D7 and requires the readback to match. Selector 3 accepts only D4 values `0x0D` (auto), `0x1D` (silent), and `0x8D` (advanced), with expected-value and readback checks. Errors do not trigger retries or guessed rollback. No selector exposes arbitrary writes.

The Swift app opens short-lived connections on explicit action. A bundled one-shot `MSIECHelper` is invoked using macOS administrator authorization for writes. It accepts only a percent and expected original byte, uses the same driver validation, and returns a JSON receipt. No installation or background service is performed by the helper.

## Evidence and limits

- msi-ec commit `d7fbbd88e6831e56801b860e46475cbf8ddbc7c1`: `CONF_G2_10`, firmware allowlist and `set_end_threshold`. https://github.com/BeardOverflow/msi-ec/blob/d7fbbd88e6831e56801b860e46475cbf8ddbc7c1/msi-ec.c
- Crosshair 16 HX D14V Windows dumps: D7 BC/D0/E4 for 60/80/100%; A0–AB decodes to 15P4EMS1.107, despite the issue's shortened firmware field. This is externally submitted evidence, not a measurement of the user's target. https://github.com/BeardOverflow/msi-ec/issues/748
- Apple IOACPIPlatformDevice address-space forwarding API: https://github.com/apple-oss-distributions/IOACPIFamily/blob/main/IOACPIPlatformDevice.cpp
- IOUserClient argument validation and administrator privilege implementation: https://github.com/apple-oss-distributions/xnu/blob/main/iokit/Kernel/IOUserClient.cpp

The app does not infer support from the marketing model. Unknown firmware allows explicit byte reads only. Startup, actual target EC access, physical charge thresholds and power-cycle persistence remain unverified. The C++ policy checks exercise production policy code offline; they do not execute kernel operations. Do not load or test this driver on the development Mac to infer target behavior.
# Mute indicators (0.3.5 / API 8)

Selector 9 accepts two scalars: LED (0 speaker, 1 microphone) and enabled (0/1).
It returns one verified boolean. This narrow operation permits local-user or
administrator callers; existing hardware-control selectors still require an
administrator. Exact firmware 15P2EMS1.110 is required. Under the shared lock,
it preserves all bits except bit 1 at 0x2D (speaker) or 0x2C (microphone), avoids
unchanged writes and verifies the entire readback byte.

Mapping reference: MControlSuite/msi-ec main, CONF_G2_10 / ALLOWED_FW_G2_10
(15P2EMS1.1); https://github.com/MControlSuite/msi-ec/blob/main/msi-ec.c

The application polls default-device CoreAudio mute properties once per second
and reconciles every ten seconds. It does not record audio or change mute.
Devices without a readable main-element mute property are skipped; application-
local microphone mute cannot be inferred. Synchronization requires the app to
remain running. This build has not been physically validated on the keyboard.

