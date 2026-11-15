@main
struct HotkeyRoutingChecks {
    static func main() {
        assert(HotkeyRouting.isBacklightKey(100, fnPressed: true))
        assert(!HotkeyRouting.isBacklightKey(100, fnPressed: false))
        for key: Int64 in [53, 79, 80, 96, 97, 98, 101] {
            assert(!HotkeyRouting.isBacklightKey(key, fnPressed: true))
        }
        for key: Int64 in [79, 80] {
            assert(HotkeyRouting.accepts(key: key, repeating: false, standaloneRunning: false, elapsed: 1))
            assert(!HotkeyRouting.accepts(key: key, repeating: true, standaloneRunning: false, elapsed: 1))
            assert(!HotkeyRouting.accepts(key: key, repeating: false, standaloneRunning: true, elapsed: 1))
            assert(!HotkeyRouting.accepts(key: key, repeating: false, standaloneRunning: false, elapsed: 0.1))
        }
        for key: Int64 in [96, 97, 118, 55] {
            assert(!HotkeyRouting.accepts(key: key, repeating: false, standaloneRunning: false, elapsed: 1))
        }
        assert(HotkeyRouting.accepts(key: 64, repeating: false, standaloneRunning: false, elapsed: 1))
        assert(HotkeyRouting.accepts(key: 64, repeating: false, standaloneRunning: true, elapsed: 1))
        assert(!HotkeyRouting.accepts(key: 64, repeating: true, standaloneRunning: false, elapsed: 1))
        assert(!HotkeyRouting.accepts(key: 64, repeating: false, standaloneRunning: false, elapsed: 0.1))
        print("Hotkey routing checks passed")
    }
}
