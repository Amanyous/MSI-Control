#!/usr/bin/env python3
from pathlib import Path
import plistlib
import shutil
import subprocess

root = Path(__file__).resolve().parents[2]
sdk = Path(subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip())
headers = sdk / "System/Library/Frameworks/Kernel.framework/Headers"
stage = root / "work/driver-build"
stage.mkdir(parents=True, exist_ok=True)
obj = stage / "MSIECBridge.o"
subprocess.run(["xcrun", "clang++", "-arch", "x86_64", "-std=c++17", "-mkernel", "-DKERNEL", "-DKERNEL_PRIVATE",
                "-fno-exceptions", "-fno-rtti", "-fapple-kext", "-fno-common", "-fno-stack-protector",
                "-mno-red-zone", "-mmacosx-version-min=14.0", "-isysroot", str(sdk),
                "-I", str(headers), "-I", str(headers / "libkern"), "-Wall", "-Wextra", "-Werror",
                "-Wno-unused-parameter", "-c", str(Path(__file__).with_name("MSIECBridge.cpp")), "-o", str(obj)], check=True)
kext = stage / "MSIECBridge.kext"
(kext / "Contents/MacOS").mkdir(parents=True, exist_ok=True)
subprocess.run(["xcrun", "ld", "-arch", "x86_64", "-kext", "-undefined", "dynamic_lookup",
                "-o", str(kext / "Contents/MacOS/MSIECBridge"), str(obj)], check=True)
plist = {
    "CFBundleDevelopmentRegion": "English", "CFBundleExecutable": "MSIECBridge",
    "CFBundleIdentifier": "org.shenying.msiecbridge", "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleName": "MSIECBridge", "CFBundlePackageType": "KEXT",
    "CFBundleShortVersionString": "0.4.9", "CFBundleVersion": "24", "OSBundleRequired": "Root",
    "OSBundleLibraries": {"com.apple.kpi.iokit": "12.0.0", "com.apple.kpi.libkern": "12.0.0",
                          "com.apple.kpi.mach": "12.0.0", "com.apple.kpi.unsupported": "12.0.0",
                          "com.apple.iokit.IOACPIFamily": "1.0.0"},
    "IOKitPersonalities": {"MSIEmbeddedControllerBridge": {
        "CFBundleIdentifier": "org.shenying.msiecbridge", "IOClass": "MSIEmbeddedControllerBridge",
        "IOProviderClass": "AppleACPIEC", "IOProbeScore": 100,
        "IOMatchCategory": "org.shenying.msiecbridge"}}
}
(kext / "Contents/Info.plist").write_bytes(plistlib.dumps(plist))
(kext / "Contents/MacOS/MSIECBridge").chmod(0o755)
destination = root / "Sources/ShenyingControl/Resources/MSIECBridge.kext"
if destination.exists(): shutil.rmtree(destination)
shutil.copytree(kext, destination, copy_function=shutil.copyfile)
(destination / "Contents/MacOS/MSIECBridge").chmod(0o755)
print("Built MSIECBridge 0.4.9 / API 15 (protocol 4, indexed background cache). Not loaded or installed.")
