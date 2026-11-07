import Foundation

/// One merged reading (macmon + native sensors). `.nan` means "not available".
struct Sample {
    var time: TimeInterval = Date().timeIntervalSince1970
    var cpu: Float = .nan          // % of all cores busy (active residency)
    var ecpu: Float = .nan         // % efficiency cluster
    var pcpu: Float = .nan         // % performance cluster
    var gpu: Float = .nan          // % (frequency-weighted, as macmon reports)
    var ramUsedGB: Float = .nan
    var ramTotalGB: Float = .nan
    var swapUsedGB: Float = .nan
    var memPressure: Int = 0       // 0 normal, 1 warn, 2 critical
    var cpuPower: Float = .nan     // W
    var gpuPower: Float = .nan
    var anePower: Float = .nan
    var sysPower: Float = .nan     // whole machine
    var batteryW: Float = .nan     // + charging, − discharging
    var batteryPct: Float = .nan
    var onAC: Bool = true
    var cpuTemp: Float = .nan      // °C
    var gpuTemp: Float = .nan
    var fan0: Float = .nan         // rpm
    var fan1: Float = .nan
    var fanMax: Float = .nan
    var fanCount: Int = 0
    var diskRead: Float = .nan     // MB/s
    var diskWrite: Float = .nan

    var ramPct: Float { ramTotalGB > 0 ? ramUsedGB / ramTotalGB * 100 : .nan }

    func value(_ s: Series) -> Float {
        switch s {
        case .cpu: return cpu
        case .ecpu: return ecpu
        case .pcpu: return pcpu
        case .gpu: return gpu
        case .ram: return ramUsedGB
        case .swap: return swapUsedGB
        case .cpuPower: return cpuPower
        case .gpuPower: return gpuPower
        case .anePower: return anePower
        case .sysPower: return sysPower
        case .batteryW: return batteryW
        case .batteryPct: return batteryPct
        case .cpuTemp: return cpuTemp
        case .gpuTemp: return gpuTemp
        case .fan0: return fan0
        case .fan1: return fan1
        case .diskRead: return diskRead
        case .diskWrite: return diskWrite
        }
    }
}

/// Series kept in history. Order is part of the history file format: append only.
enum Series: Int, CaseIterable {
    case cpu, ecpu, pcpu, gpu, ram, swap, cpuPower, gpuPower, anePower, sysPower
    case batteryW, batteryPct, cpuTemp, gpuTemp, fan0, fan1, diskRead, diskWrite

    var csvName: String {
        switch self {
        case .cpu: return "cpu_pct"
        case .ecpu: return "ecpu_pct"
        case .pcpu: return "pcpu_pct"
        case .gpu: return "gpu_pct"
        case .ram: return "ram_gb"
        case .swap: return "swap_gb"
        case .cpuPower: return "cpu_w"
        case .gpuPower: return "gpu_w"
        case .anePower: return "ane_w"
        case .sysPower: return "system_w"
        case .batteryW: return "battery_w"
        case .batteryPct: return "battery_pct"
        case .cpuTemp: return "cpu_temp_c"
        case .gpuTemp: return "gpu_temp_c"
        case .fan0: return "fan0_rpm"
        case .fan1: return "fan1_rpm"
        case .diskRead: return "disk_read_mbs"
        case .diskWrite: return "disk_write_mbs"
        }
    }
}

enum Level: Int { case normal, warn, critical }

/// Metrics that can be placed in the menu bar.
enum BarMetric: String, CaseIterable {
    case cpu, gpu, ram, ramGB, swap, power, cpuPower, gpuPower, battery, batteryPct, cpuTemp, gpuTemp, fan, disk

    var title: String {
        switch self {
        case .cpu: return "CPU usage"
        case .gpu: return "GPU usage"
        case .ram: return "RAM used (%)"
        case .ramGB: return "RAM used (GB)"
        case .swap: return "Swap used"
        case .power: return "System power"
        case .cpuPower: return "CPU power"
        case .gpuPower: return "GPU power"
        case .battery: return "Battery charge/discharge"
        case .batteryPct: return "Battery level"
        case .cpuTemp: return "CPU temperature"
        case .gpuTemp: return "GPU temperature"
        case .fan: return "Fan speed"
        case .disk: return "Disk read + write"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: return "cpu"
        case .gpu: return "display"
        case .ram, .ramGB: return "memorychip"
        case .swap: return "arrow.left.arrow.right"
        case .power: return "bolt.fill"
        case .cpuPower, .gpuPower: return "bolt"
        case .battery, .batteryPct: return "battery.75"
        case .cpuTemp, .gpuTemp: return "thermometer.medium"
        case .fan: return "fanblades"
        case .disk: return "internaldrive"
        }
    }

    /// Widest text this metric can show; fixes the column width so the bar never jitters.
    var widthTemplate: String {
        switch self {
        case .cpu, .gpu, .ram, .batteryPct: return "100%"
        case .ramGB, .swap: return "8.8G"
        case .power, .cpuPower, .gpuPower: return "8.8W"
        case .battery: return "−8.8W"
        case .cpuTemp, .gpuTemp: return "100°"
        case .fan: return "8.8k"
        case .disk: return "888M"
        }
    }

    func text(_ s: Sample) -> String {
        switch self {
        case .cpu: return Fmt.pct(s.cpu)
        case .gpu: return Fmt.pct(s.gpu)
        case .ram: return Fmt.pct(s.ramPct)
        case .ramGB: return Fmt.gb(s.ramUsedGB)
        case .swap: return Fmt.gb(s.swapUsedGB)
        case .power: return Fmt.watts(s.sysPower)
        case .cpuPower: return Fmt.watts(s.cpuPower)
        case .gpuPower: return Fmt.watts(s.gpuPower)
        case .battery: return Fmt.signedWatts(s.batteryW)
        case .batteryPct: return Fmt.pct(s.batteryPct)
        case .cpuTemp: return Fmt.temp(s.cpuTemp)
        case .gpuTemp: return Fmt.temp(s.gpuTemp)
        case .fan: return Fmt.rpmShort(Self.fanValue(s))
        case .disk: return Fmt.mbShort(s.diskRead + s.diskWrite)
        }
    }

    func level(_ s: Sample, _ t: Thresholds) -> Level {
        switch self {
        case .cpu: return s.cpu >= t.cpu ? .critical : .normal
        case .gpu: return s.gpu >= t.gpu ? .critical : .normal
        case .ram, .ramGB:
            if s.ramPct >= t.ram || s.memPressure >= 2 { return .critical }
            return s.memPressure == 1 ? .warn : .normal
        case .cpuTemp, .gpuTemp:
            let v = self == .cpuTemp ? s.cpuTemp : s.gpuTemp
            if v >= t.temp { return .critical }
            return v >= t.temp - 10 ? .warn : .normal
        case .battery, .batteryPct:
            return (!s.onAC && s.batteryPct <= 10) ? .critical : .normal
        default: return .normal
        }
    }

    /// The number behind `text(_:)`, used to decide whether a change is worth redrawing.
    func value(_ s: Sample) -> Float {
        switch self {
        case .cpu: return s.cpu
        case .gpu: return s.gpu
        case .ram: return s.ramPct
        case .ramGB: return s.ramUsedGB
        case .swap: return s.swapUsedGB
        case .power: return s.sysPower
        case .cpuPower: return s.cpuPower
        case .gpuPower: return s.gpuPower
        case .battery: return s.batteryW
        case .batteryPct: return s.batteryPct
        case .cpuTemp: return s.cpuTemp
        case .gpuTemp: return s.gpuTemp
        case .fan: return Self.fanValue(s)
        case .disk: return s.diskRead + s.diskWrite
        }
    }

    /// Smallest change from the shown value that is worth a menu bar redraw ("steady" mode).
    func step(from shown: Float) -> Float {
        let a = abs(shown)
        switch self {
        case .cpu, .gpu: return 3
        case .ram, .batteryPct: return 1
        case .ramGB, .swap: return 0.1
        case .cpuTemp, .gpuTemp: return 2
        case .power, .cpuPower, .gpuPower, .battery: return max(0.5, a * 0.15)
        case .fan: return max(100, a * 0.1)
        case .disk: return max(1, a * 0.25)
        }
    }

    static func fanValue(_ s: Sample) -> Float {
        let a = s.fan0.isFinite ? s.fan0 : 0, b = s.fan1.isFinite ? s.fan1 : 0
        return s.fan0.isFinite || s.fan1.isFinite ? max(a, b) : .nan
    }
}

struct Thresholds {
    var cpu: Float
    var gpu: Float
    var ram: Float
    var temp: Float
}

enum Fmt {
    static let dash = "–"
    static func pct(_ v: Float) -> String { v.isFinite ? "\(Int(v.rounded()))%" : dash }
    static func temp(_ v: Float) -> String { v.isFinite ? "\(Int(v.rounded()))°" : dash }
    static func watts(_ v: Float) -> String {
        guard v.isFinite else { return dash }
        return v < 9.95 ? String(format: "%.1fW", v) : String(format: "%.0fW", v)
    }
    static func signedWatts(_ v: Float) -> String {
        guard v.isFinite else { return dash }
        let sign = v < -0.05 ? "−" : (v > 0.05 ? "+" : "")
        let a = abs(v)
        return sign + (a < 9.95 ? String(format: "%.1fW", a) : String(format: "%.0fW", a))
    }
    static func gb(_ v: Float) -> String {
        guard v.isFinite else { return dash }
        return v < 9.95 ? String(format: "%.1fG", v) : String(format: "%.0fG", v)
    }
    static func rpmShort(_ v: Float) -> String {
        guard v.isFinite else { return dash }
        if v < 1 { return "0" }
        return v < 1000 ? "\(Int(v))" : String(format: "%.1fk", v / 1000)
    }
    static func mbShort(_ v: Float) -> String {
        guard v.isFinite else { return dash }
        if v >= 999.5 { return String(format: "%.1fG", v / 1000) }
        return v < 9.95 ? String(format: "%.1fM", v) : String(format: "%.0fM", v)
    }
    /// Plain number: one decimal below 10, none above.
    static func num(_ v: Float) -> String {
        guard v.isFinite else { return dash }
        return v < 9.95 ? String(format: "%.1f", v) : String(format: "%.0f", v)
    }
    static func bytes(_ b: Double) -> String {
        if b >= 1e9 { return String(format: "%.1fG", b / 1e9) }
        if b >= 1e6 { return String(format: "%.0fM", b / 1e6) }
        return String(format: "%.0fK", b / 1e3)
    }
    static func rate(_ bps: Double?) -> String {
        guard let b = bps else { return dash }
        if b < 50_000 { return "0" }
        if b >= 1e9 { return String(format: "%.1fG/s", b / 1e9) }
        return b < 9.95e6 ? String(format: "%.1fM/s", b / 1e6) : String(format: "%.0fM/s", b / 1e6)
    }
}
