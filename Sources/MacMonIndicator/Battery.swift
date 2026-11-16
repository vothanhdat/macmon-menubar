import Foundation
import IOKit

/// What process history needs to know about the battery: whether the Mac runs on it, and how much
/// energy a full charge holds. Public IOKit registry properties; read when asked (a scan every
/// 5 minutes), nothing is kept open. Any queue.
enum Battery {
    private static func read<T>(_ body: (_ num: (String) -> Double?) -> T?) -> T? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        func property(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        // Newer versions of macOS keep the capacities inside "BatteryData".
        var data: [String: Any]?
        return body { key in
            if let n = property(key) as? NSNumber { return n.doubleValue }
            if data == nil { data = property("BatteryData") as? [String: Any] ?? [:] }
            return (data?[key] as? NSNumber)?.doubleValue
        }
    }

    /// Running on the battery now. Nil on a Mac without one.
    static func onBattery() -> Bool? {
        read { num in num("ExternalConnected").map { $0 == 0 } }
    }

    /// The energy of a full charge as the battery is now, in watt-hours; nil on a Mac without a
    /// battery. Read once.
    static let capacityWh: Double? = read { num in
        guard let mAh = num("AppleRawMaxCapacity") ?? num("NominalChargeCapacity") ?? num("DesignCapacity"),
              let mV = num("Voltage") else { return nil }
        return wattHours(mAh: mAh, mV: mV)
    }

    /// The battery says its capacity in mAh, and not its nominal voltage: that is 3.8 V per cell,
    /// with the number of cells in series worked out from the voltage now (3.3 to 4.4 V each).
    static func wattHours(mAh: Double, mV: Double) -> Double? {
        let cells = (mV / 3900).rounded()
        guard mAh > 0, cells >= 1 else { return nil }
        return mAh * cells * 3.8 / 1000
    }
}
