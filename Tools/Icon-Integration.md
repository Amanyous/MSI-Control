# App Icon

The approved silver/graphite concept is preserved in `AppIcon-Master.png`.
`BuildIcon.swift` removes the opaque presentation corners and generates the ten
standard iconset PNG representations. Compile the result with `iconutil -c icns`.
The resulting `Resources/AppIcon.icns` is the app's static compatibility icon.

`PackageIconBuild.swift` copies an existing app without modifying its functional
source code, installs actool's compiled resources, and merges its partial plist.
The resulting app must be ad-hoc signed and verified after packaging.
Version 0.2.62 uses 0.2.61 as its base and retains macOS 14 as its minimum.

## Compatibility Status

- Static ICNS: 16 through 1024 pixels, including Retina representations.
- macOS 14 and newer: standard bundle icon registration; no new runtime APIs.
- macOS 26 layered icon: `Design/AppIcon.icon` contains separately authored SVG
  mark and accent layers, with lighting rendered by Icon Composer.
- Xcode 26.5 actool successfully compiled the document with deployment target
  14.0, producing Assets.car, AppIcon.icns and icon-info.plist.
- assetutil confirms IconImageStack resources and Aqua, DarkAqua and Tintable
  appearance entries. This checks resource presence, not visual correctness.
- Both CFBundleIconName and CFBundleIconFile are registered.
- Version 0.2.62 passed deep/strict ad-hoc signature verification.
- No macOS 14/15 device testing or macOS 26 dynamic-appearance testing was performed.
- Default Composer preview was visually inspected. Dark and tinted appearances
  still require visual testing before claiming full appearance validation.
