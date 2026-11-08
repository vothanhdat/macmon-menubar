import Foundation
import IOKit

/// Sensors macmon does not report: total disk throughput and operations, and battery power.
/// Uses public IOKit registry properties only; no root needed.
/// Not thread-safe: call from one queue.
final class SystemSensors {
    private var lastDisk: (read: UInt64, write: UInt64, readOps: UInt64, writeOps: UInt64, time: TimeInterval)?
    private let battery: io_service_t

    init() {
        battery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    }

    deinit { if battery != 0 { IOObjectRelease(battery) } }

    var hasBattery: Bool { battery != 0 }

    /// Disk read/write in MB/s, and read/write operations per second, since the previous call
    /// (summed over all block devices). Many small reads or writes show up as many operations
    /// even when the MB/s stay low.
    func readDisk(now: TimeInterval) -> (read: Float, write: Float, readOps: Float, writeOps: Float) {
        let none: (Float, Float, Float, Float) = (.nan, .nan, .nan, .nan)
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iter) == KERN_SUCCESS else {
            return none
        }
        defer { IOObjectRelease(iter) }
        var r: UInt64 = 0, w: UInt64 = 0, ro: UInt64 = 0, wo: UInt64 = 0
        var service = IOIteratorNext(iter)
        while service != 0 {
            if let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] {
                func count(_ key: String) -> UInt64 { (stats[key] as? NSNumber)?.uint64Value ?? 0 }
                r &+= count("Bytes (Read)")
                w &+= count("Bytes (Write)")
                ro &+= count("Operations (Read)")
                wo &+= count("Operations (Write)")
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iter)
        }
        defer { lastDisk = (r, w, ro, wo, now) }
        guard let last = lastDisk, now > last.time, r >= last.read, w >= last.write,
              ro >= last.readOps, wo >= last.writeOps else { return none }
        let dt = now - last.time
        let rate = { (a: UInt64, b: UInt64) in Float(Double(a - b) / dt) }
        return (rate(r, last.read) / 1e6, rate(w, last.write) / 1e6, rate(ro, last.readOps), rate(wo, last.writeOps))
    }

    /// Battery power (W, + charging / − discharging), level (%), and whether external power is connected.
    func readBattery() -> (watts: Float, pct: Float, onAC: Bool)? {
        guard battery != 0 else { return nil }
        func num(_ key: String) -> NSNumber? {
            IORegistryEntryCreateCFProperty(battery, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
        }
        let mV = num("Voltage")?.doubleValue ?? .nan
        // Stored as a 64-bit value that wraps for negative currents; int64Value restores the sign.
        let mA = (num("InstantAmperage") ?? num("Amperage"))?.int64Value ?? 0
        let pct = num("CurrentCapacity")?.floatValue ?? .nan
        let ac = num("ExternalConnected")?.boolValue ?? true
        return (Float(mV * Double(mA) / 1e6), pct, ac)
    }
}
