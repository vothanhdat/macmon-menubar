import AppKit
import Darwin

/// Memory numbers as Activity Monitor shows them (phys_footprint) plus the malloc heap.
enum MemoryProbe {
    static func vmInfo() -> task_vm_info_data_t {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return info
    }

    static func footprint() -> Double { Double(vmInfo().phys_footprint) / 1_048_576 }

    /// Set by MenuCycler; menu open/close also report then.
    static var enabled = false

    static func report(_ tag: String) {
        var s = malloc_statistics_t()
        malloc_zone_statistics(nil, &s)
        let t = ProcessInfo.processInfo.systemUptime
        let vm = vmInfo()
        let line = String(format: "[mem] %7.1f %@: footprint %.1f MB, RSS %.1f MB, malloc in use %.1f MB, images %d",
                          t, tag, Double(vm.phys_footprint) / 1_048_576, Double(vm.resident_size) / 1_048_576,
                          Double(s.size_in_use) / 1_048_576, _dyld_image_count())
        log.notice("\(line, privacy: .public)")
        FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
    }
}

/// Development aid for measuring memory the same way every time:
/// `MACMON_DEBUG_MENU_CYCLES=3` opens the menu, keeps it open a few seconds
/// (`MACMON_DEBUG_MENU_HOLD`, default 6 s), closes it, and logs the memory at fixed times after
/// each close (`MACMON_DEBUG_MENU_GAP`, default 60 s, between opens). Output goes to stderr and the log.
final class MenuCycler {
    private let menu: NSMenu
    private let anchor: NSView
    private var left: Int
    private let hold: TimeInterval
    private let gap: TimeInterval

    init?(menu: NSMenu, anchor: NSView?) {
        let env = ProcessInfo.processInfo.environment
        guard let n = env["MACMON_DEBUG_MENU_CYCLES"].flatMap(Int.init), n > 0, let anchor else { return nil }
        MemoryProbe.enabled = true
        self.menu = menu
        self.anchor = anchor
        left = n
        hold = env["MACMON_DEBUG_MENU_HOLD"].flatMap(Double.init) ?? 6
        gap = env["MACMON_DEBUG_MENU_GAP"].flatMap(Double.init) ?? 60
    }

    func start() {
        MemoryProbe.report("launch")
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { self.cycle() } // after the 20 s launch baseline
    }

    private func cycle() {
        guard left > 0 else {
            MemoryProbe.report("done")
            // MACMON_DEBUG_FAKE_DISPLAY_SLEEP=1: pretend the displays went to sleep, to test the quiet restart.
            if ProcessInfo.processInfo.environment["MACMON_DEBUG_FAKE_DISPLAY_SLEEP"] != nil {
                NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
            }
            return
        }
        left -= 1
        MemoryProbe.report("before open")
        let t = Timer(timeInterval: hold, repeats: false) { [menu] _ in
            MemoryProbe.report("open, closing")
            menu.cancelTracking()
        }
        RunLoop.main.add(t, forMode: .common)
        // On recent macOS this returns before the menu has closed, so times count from here.
        // The glass effect's graphics memory (up to ~170 MB while open, freed 20-40 s after
        // closing) doesn't always appear for a popped-up menu; the rest matches a real click.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
        for after in [1.0, 10, 30, 50] where hold + after < gap {
            DispatchQueue.main.asyncAfter(deadline: .now() + hold + after) { MemoryProbe.report("closed +\(Int(after)) s") }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + gap) { self.cycle() }
    }
}
