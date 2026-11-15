#!/bin/zsh
set -euo pipefail
source_root="${0:A:h:h}"
output_directory="${1:?Pass the app Contents/Resources directory}"
mkdir -p "$output_directory"
xcrun xcstringstool compile "$source_root/Sources/ShenyingControl/Localizable.xcstrings" --output-directory "$output_directory"
