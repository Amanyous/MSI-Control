#!/bin/zsh
set -euo pipefail
source_root="${0:A:h:h}"
base_app="${1:?Pass the base app path}"
target_app="${2:?Pass the new app path}"
binary="${3:?Pass the newly built MSIControl executable}"
identity="${CODE_SIGN_IDENTITY:-MSI Control Local Signing}"
if [[ -z "$identity" || "$identity" == "-" ]]; then
    if [[ "${ALLOW_ADHOC_SIGNING:-0}" != "1" ]]; then
        print -u2 "Set CODE_SIGN_IDENTITY to your persistent signing certificate (prefer its SHA-1)."
        print -u2 "Ad-hoc signing changes privacy identity on each build. For test builds only, set ALLOW_ADHOC_SIGNING=1."
        exit 1
    fi
    identity="-"
    print -u2 "WARNING: ad-hoc test build; privacy permissions may need to be granted again after updates."
else
    identities="$(security find-identity -v -p codesigning)"
    if ! print -r -- "$identities" | grep -F -- "$identity" >/dev/null; then
        print -u2 "The requested signing identity is not available: $identity"
        exit 1
    fi
fi
[[ ! -e "$target_app" ]] || { print -u2 "Output already exists"; exit 1; }
ditto "$base_app" "$target_app"
cp "$binary" "$target_app/Contents/MacOS/MSIControl"
power_service="${binary:h}/MSIPowerService"
[[ -x "$power_service" ]] || { print -u2 "Build MSIPowerService before packaging"; exit 1; }
cp "$power_service" "$target_app/Contents/MacOS/MSIPowerService"
mkdir -p "$target_app/Contents/Library/LaunchDaemons"
cp "$source_root/Tools/org.shenying.mcontrol.power.plist" "$target_app/Contents/Library/LaunchDaemons/"
codesign --force --identifier org.shenying.mcontrol.power --sign "$identity" \
  "$target_app/Contents/MacOS/MSIPowerService"
# Always replace both resource locations; the base app may contain an older driver.
driver="$source_root/Sources/ShenyingControl/Resources/MSIECBridge.kext"
driver_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$driver/Contents/Info.plist")"
driver_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$driver/Contents/Info.plist")"
driver_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$driver/Contents/Info.plist")"
[[ -n "${driver_version//[[:space:]]/}" && "$driver_identifier" == "org.shenying.msiecbridge" &&
   "$driver_executable" == "MSIECBridge" && -x "$driver/Contents/MacOS/MSIECBridge" ]] || {
    print -u2 "Bundled EC driver identity, version metadata or executable is invalid"
    exit 1
}
ditto "$driver" "$target_app/Contents/Resources/MSIECBridge.kext"
ditto "$driver" "$target_app/Contents/Resources/MSIControl_MSIControl.bundle/Resources/MSIECBridge.kext"
zsh "$source_root/Tools/CompileLocalizations.command" "$target_app/Contents/Resources"
plist="$target_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName MSI Control' \
  -c 'Set :CFBundleName MSI Control' \
  -c "Set :CFBundleShortVersionString ${APP_VERSION:?Set APP_VERSION}" \
  -c "Set :CFBundleVersion ${APP_BUILD:?Set APP_BUILD}" "$plist"
codesign --force --sign "$identity" "$target_app"
codesign --verify --deep --strict "$target_app"
