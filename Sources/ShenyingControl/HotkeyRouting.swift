enum HotkeyRouting {
    static func isBacklightKey(_ key: Int64, fnPressed: Bool) -> Bool {
        key == 100 && fnPressed
    }

    static func accepts(key: Int64, repeating: Bool, standaloneRunning: Bool, elapsed: Double) -> Bool {
        (key == 64 || ((key == 79 || key == 80) && !standaloneRunning)) && !repeating && elapsed > 0.6
    }
}
