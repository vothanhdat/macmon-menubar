import Foundation
import IOKit

/// Sensors macmon does not report: total disk throughput and battery power.
/// Uses public IOKit registry properties only; no root needed.
/// Not thread-safe: call from one queue.
final class SystemSensors {
    private var lastDisk: (read: UInt64, write: UInt64, time: TimeInterval)?
    private let battery: io_service_t

    init() {
        battery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    }

    deinit { if battery != 0 { IOObjectRelease(battery) } }

    var hasBattery: Bool { battery != 0 }

    /// Disk read/write in MB/s since the previous call (summed over all block devices).
    func readDisk(now: TimeInterval) -> (read: Float, write: Float) {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iter) == KERN_SUCCESS else {
            return (.nan, .nan)
        }
        defer { IOObjectRelease(iter) }
        var r: UInt64 = 0, w: UInt64 = 0
        var service = IOIteratorNext(iter)
        while service != 0 {
            if let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] {
                r &+= (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                w &+= (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iter)
        }
        defer { lastDisk = (r, w, now) }
        guard let last = lastDisk, now > last.time, r >= last.read, w >= last.write else { return (.nan, .nan) }
        let dt = now - last.time
        return (Float(Double(r - last.read) / dt / 1e6), Float(Double(w - last.write) / dt / 1e6))
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
