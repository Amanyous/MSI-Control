import Foundation

guard CommandLine.arguments.count == 4 else {
    fatalError("Usage: swift Tools/PackageIconBuild.swift base.app new.app compiled-icon-directory")
}
let files = FileManager.default
let base = URL(fileURLWithPath: CommandLine.arguments[1])
let target = URL(fileURLWithPath: CommandLine.arguments[2])
let compiled = URL(fileURLWithPath: CommandLine.arguments[3])
for name in ["AppIcon.icns", "Assets.car", "icon-info.plist"] {
    guard files.fileExists(atPath: compiled.appendingPathComponent(name).path) else {
        fatalError("Missing compiled resource: \(name)")
    }
}
guard !files.fileExists(atPath: target.path) else {
    fatalError("Output already exists; refusing to overwrite")
}
try files.copyItem(at: base, to: target)
for name in ["AppIcon.icns", "Assets.car"] {
    let destination = target.appendingPathComponent("Contents/Resources/\(name)")
    if files.fileExists(atPath: destination.path) {
        try files.removeItem(at: destination)
    }
    try files.copyItem(at: compiled.appendingPathComponent(name), to: destination)
}
let plistURL = target.appendingPathComponent("Contents/Info.plist")
var plist = try PropertyListSerialization.propertyList(
    from: Data(contentsOf: plistURL), format: nil
) as! [String: Any]
let iconInfo = try PropertyListSerialization.propertyList(
    from: Data(contentsOf: compiled.appendingPathComponent("icon-info.plist")), format: nil
) as! [String: Any]
plist.merge(iconInfo) { _, compiledValue in compiledValue }
plist["CFBundleShortVersionString"] = "0.2.62"
plist["CFBundleVersion"] = "62"
try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    .write(to: plistURL)
