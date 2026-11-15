#!/bin/zsh
set -euo pipefail
source_app="${1:?Pass the packaged app path}"
target="/Applications/MSI Control.app"
[[ "$source_app" != "$target" ]] || exit 1
codesign --verify --deep --strict "$source_app"
if [[ -e "$target" ]]; then
    backup="$HOME/Library/Application Support/MSI Control/Backups/$(date +%Y%m%d-%H%M%S)/MSI Control.app"
    mkdir -p "${backup:h}"
    ditto "$target" "$backup"
fi
ditto "$source_app" "$target"
codesign --verify --deep --strict "$target"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$target"
open "$target"
