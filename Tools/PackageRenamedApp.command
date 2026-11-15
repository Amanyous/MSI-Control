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
zsh "$source_root/Tools/CompileLocalizations.command" "$target_app/Contents/Resources"
plist="$target_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName MSI Control' \
  -c 'Set :CFBundleName MSI Control' \
  -c "Set :CFBundleShortVersionString ${APP_VERSION:?Set APP_VERSION}" \
  -c "Set :CFBundleVersion ${APP_BUILD:?Set APP_BUILD}" "$plist"
codesign --force --sign "$identity" "$target_app"
codesign --verify --deep --strict "$target_app"
