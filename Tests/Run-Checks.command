#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
cd "$SCRIPT_DIR/.."
mkdir -p work
BUILD_PATH="$(swift build --disable-sandbox --show-bin-path)"
swift build --disable-sandbox
"$BUILD_PATH/SystemSensorChecks"
xcrun swiftc -swift-version 6 -module-cache-path .build/ModuleCache \
  Sources/KeyboardLighting/LightingConfiguration.swift \
  Sources/KeyboardLighting/MysticLightProtocol.swift \
  Sources/KeyboardLighting/LightingTransaction.swift \
  Tests/KeyboardLightingTests/KeyboardLightingTests.swift \
  -o work/keyboard-lighting-checks
./work/keyboard-lighting-checks
xcrun swiftc -swift-version 6 -module-cache-path .build/ModuleCache \
  -I "$BUILD_PATH/Modules" \
  Sources/ShenyingControl/KeyboardLightingModel.swift \
  Sources/ShenyingControl/KeyboardLightingAgent.swift \
  Sources/ShenyingControl/Localization.swift \
  Tests/KeyboardLightingTests/KeyboardLightingModelChecks.swift \
  "$BUILD_PATH/ECControl.build/ECChargePolicy.swift.o" \
  "$BUILD_PATH/ECControl.build/ECFeatureProfiles.swift.o" \
  "$BUILD_PATH/ECControl.build/ECBridgeConnection.swift.o" \
  "$BUILD_PATH/ECControl.build/BatteryStatus.swift.o" \
  "$BUILD_PATH/KeyboardLighting.build/LightingConfiguration.swift.o" \
  "$BUILD_PATH/KeyboardLighting.build/MysticLightProtocol.swift.o" \
  "$BUILD_PATH/KeyboardLighting.build/LightingTransaction.swift.o" \
  "$BUILD_PATH/KeyboardLighting.build/KeyboardHIDService.swift.o" \
  "$BUILD_PATH/KeyboardLighting.build/LightingAgentConfiguration.swift.o" \
  -o work/keyboard-lighting-model-checks
./work/keyboard-lighting-model-checks
xcrun swiftc -swift-version 6 -module-cache-path .build/ModuleCache \
  Sources/ECControl/ECFeatureProfiles.swift Sources/ECControl/ECChargePolicy.swift Sources/ECControl/BatteryStatus.swift \
  Tests/ECControlTests/ECControlChecks.swift -o work/ec-control-checks
./work/ec-control-checks
xcrun swiftc -swift-version 6 -module-cache-path .build/ModuleCache \
  -I "$BUILD_PATH/Modules" \
  Sources/ShenyingControl/BatteryModel.swift Tests/ECControlTests/BatteryModelChecks.swift \
  "$BUILD_PATH/ECControl.build/ECChargePolicy.swift.o" \
  "$BUILD_PATH/ECControl.build/ECFeatureProfiles.swift.o" \
  "$BUILD_PATH/ECControl.build/ECBridgeConnection.swift.o" \
  "$BUILD_PATH/ECControl.build/BatteryStatus.swift.o" \
  -o work/battery-model-checks
./work/battery-model-checks
xcrun clang++ -std=c++17 -Wall -Wextra -Werror Tests/ECControlTests/ECPolicyChecks.cpp -o work/ec-kernel-policy-checks
./work/ec-kernel-policy-checks
python3 Drivers/MSIECBridge/build.py
