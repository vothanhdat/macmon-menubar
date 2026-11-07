import Foundation

/// Runs `macmon pipe` as a child process and turns each JSON line into a `Sample`.
/// Control methods must be called on the main thread; `onSample` is delivered on main.
final class MacmonSource {
    enum State: Equatable { case stopped, running, notFound, failed }

    var onSample: ((Sample) -> Void)?
    var onState: ((State) -> Void)?
    private(set) var state: State = .stopped { didSet { if state != oldValue { onState?(state) } } }
    private(set) var intervalMs = 2000
    private(set) var path: String?

    private let sensors = SystemSensors()
    private var process: Process?
    private var generation = 0
    private var wantRunning = false
    private var restartDelay: TimeInterval = 1
    private var retryWork: DispatchWorkItem?

    var hasBattery: Bool { sensors.hasBattery }

    static func locate(override: String?) -> String? {
        var candidates: [String] = []
        if let o = override, !o.isEmpty { candidates.append(o) }
        candidates += ["/opt/homebrew/bin/macmon", "/usr/local/bin/macmon", NSHomeDirectory() + "/.cargo/bin/macmon"]
        if let p = ProcessInfo.processInfo.environment["PATH"] {
            candidates += p.split(separator: ":").map { "\($0)/macmon" }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func start(intervalMs: Int) {
        self.intervalMs = intervalMs
        wantRunning = true
        launch()
    }

    func stop() {
        wantRunning = false
        retryWork?.cancel()
        terminateChild()
        state = .stopped
    }

    /// Restarts macmon only when the interval actually changes.
    func setInterval(_ ms: Int) {
        guard ms != intervalMs || process == nil else { return }
        intervalMs = ms
        if wantRunning { launch() }
    }

    private func terminateChild() {
        generation += 1
        if let p = process {
            (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            if p.isRunning { p.terminate() }
        }
        process = nil
    }

    private func scheduleRetry() {
        retryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.wantRunning else { return }
            self.launch()
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + restartDelay, execute: work)
        restartDelay = min(restartDelay * 2, 30)
    }

    private func launch() {
        terminateChild()
        retryWork?.cancel()
        guard let path = Self.locate(override: Settings.shared.macmonPath) else {
            self.path = nil
            state = .notFound
            restartDelay = 30
            scheduleRetry()
            return
        }
        self.path = path

        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["pipe", "-i", String(intervalMs)]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice

        let gen = generation
        let reader = LineReader(sensors: sensors) { [weak self] sample in
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                self.restartDelay = 1
                self.state = .running
                self.onSample?(sample)
            }
        }
        out.fileHandleForReading.readabilityHandler = { fh in
            let data = fh.availableData
            if data.isEmpty { fh.readabilityHandler = nil; return }
            reader.consume(data)
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.generation == gen, self.wantRunning else { return }
                log.error("macmon exited unexpectedly, retrying in \(self.restartDelay) s")
                self.process = nil
                self.state = .failed
                self.scheduleRetry()
            }
        }
        do {
            try p.run()
            process = p
            log.notice("macmon started: pid \(p.processIdentifier), interval \(self.intervalMs) ms")
        } catch {
            state = .failed
            scheduleRetry()
        }
    }
}

/// Splits the byte stream into lines and decodes each one. Runs on the pipe's handler queue (serial).
private final class LineReader {
    private var buffer = Data()
    private let decoder = JSONDecoder()
    private let sensors: SystemSensors
    private let emit: (Sample) -> Void

    init(sensors: SystemSensors, emit: @escaping (Sample) -> Void) {
        self.sensors = sensors
        self.emit = emit
    }

    func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let s = decode(line) { emit(s) }
        }
        if buffer.count > 1 << 20 { buffer.removeAll() } // never grow unbounded on garbage input
    }

    private func decode(_ line: Data) -> Sample? {
        guard let j = try? decoder.decode(MacmonJSON.self, from: line) else { return nil }
        var s = Sample()
        let pct: (Float?) -> Float = { $0.map { $0 * 100 } ?? .nan }
        s.cpu = pct(j.cpu_active_ratio)
        s.ecpu = pct(j.ecpu_active_ratio)
        s.pcpu = pct(j.pcpu_active_ratio)
        s.gpu = pct(j.gpu_usage?.last)
        if let m = j.memory {
            let gib: Float = 1_073_741_824 // binary GB, as macOS shows memory
            s.ramUsedGB = Float(m.ram_usage ?? 0) / gib
            s.ramTotalGB = Float(m.ram_total ?? 0) / gib
            s.swapUsedGB = Float(m.swap_usage ?? 0) / gib
            s.memPressure = m.pressure_level ?? 0
        }
        s.cpuPower = j.cpu_power ?? .nan
        s.gpuPower = j.gpu_power ?? .nan
        s.anePower = j.ane_power ?? .nan
        s.sysPower = j.sys_power ?? .nan
        s.cpuTemp = j.temp?.cpu_temp_avg ?? .nan
        s.gpuTemp = j.temp?.gpu_temp_avg ?? .nan
        if let fans = j.fans {
            s.fanCount = fans.count
            if fans.count > 0 { s.fan0 = fans[0].rpm ?? .nan }
            if fans.count > 1 { s.fan1 = fans[1].rpm ?? .nan }
            s.fanMax = fans.compactMap(\.max_rpm).max() ?? .nan
        }
        let disk = sensors.readDisk(now: s.time)
        s.diskRead = disk.read
        s.diskWrite = disk.write
        if let b = sensors.readBattery() {
            s.batteryW = b.watts
            s.batteryPct = b.pct
            s.onAC = b.onAC
        }
        return s
    }
}

/// Only the fields we use; everything else in macmon's output is skipped.
private struct MacmonJSON: Decodable {
    struct Memory: Decodable {
        let ram_total: Double?
        let ram_usage: Double?
        let swap_usage: Double?
        let pressure_level: Int?
    }
    struct Temp: Decodable {
        let cpu_temp_avg: Float?
        let gpu_temp_avg: Float?
    }
    struct Fan: Decodable {
        let rpm: Float?
        let max_rpm: Float?
    }
    let cpu_active_ratio: Float?
    let ecpu_active_ratio: Float?
    let pcpu_active_ratio: Float?
    let gpu_usage: [Float]?
    let memory: Memory?
    let cpu_power: Float?
    let gpu_power: Float?
    let ane_power: Float?
    let sys_power: Float?
    let temp: Temp?
    let fans: [Fan]?
}
