import AppKit
import CryptoKit
import IOKit
import SystemConfiguration

/// This Mac, as your other Macs see it (see OtherMacs).
enum ThisMac {
    /// Stays the same and differs on every Mac: a hash of the hardware UUID, so a Mac set up from
    /// another one's backup (with its settings) still gets an ID of its own. MACMON_DEBUG_MAC_ID:
    /// for testing two copies of the app on one Mac.
    static let id: String = {
        if let v = ProcessInfo.processInfo.environment["MACMON_DEBUG_MAC_ID"], !v.isEmpty { return v }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        let uuid = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String ?? TerminalServer.hostName
        return SHA256.hash(data: Data("MacMonIndicator:\(uuid)".utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }()

    /// The name in System Settings → General → Sharing, e.g. "Dat's Mac mini".
    static var name: String {
        if let v = ProcessInfo.processInfo.environment["MACMON_DEBUG_MAC_NAME"], !v.isEmpty { return v }
        return (SCDynamicStoreCopyComputerName(nil, nil) as String?).flatMap { $0.isEmpty ? nil : $0 } ?? TerminalServer.hostName
    }

    /// "Mac16,10".
    static let model: String = {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        return sysctlbyname("hw.model", &buf, &size, nil, 0) == 0 ? String(cString: buf) : ""
    }()
}

/// The shared folder in iCloud Drive and what's in it. Each Mac writes only inside its own folder,
/// so iCloud never has two versions of one file to choose between:
///
///     iCloud Drive/MacMon Indicator/<mac id>/
///         info.json       name, when it was published, the latest reading, top processes,
///                         and the requests it answers
///         history.bin     a copy of that Mac's history.bin (HistoryStore)
///         process-history.sqlite.lzfse
///                         a copy of its process history (ProcessTracker.makeCopy), compressed;
///                         only while process history is on there
///         requests.json   that Mac asking others to publish now, one token per Mac it asks
///
/// Files are written to a temporary file and renamed, so a reader never sees half of one.
/// Plain file reads and writes and decisions, no state: any queue, and the tests.
struct ShareFolder {
    let root: URL
    /// This Mac's ID (ThisMac.id).
    let me: String

    struct Info: Codable {
        var format = 1
        var id: String
        var name: String
        var model: String?
        var app: String?
        /// Seconds since 1970, by the publishing Mac's clock.
        var published: Double
        var hasBattery: Bool
        /// Sample.values
        var latest: [String: Float]
        /// The top processes (by each column), from a scan at `processesTime`.
        var processes: ProcSnapshot?
        var processesTime: Double?
        /// Requester's ID → the token of its newest request that this publish answers.
        var answered: [String: String]
        /// When the process history copy in the folder was made; nil: there is none (process
        /// history is off there, or the app is from before it was shared).
        var processHistory: Double? = nil
    }

    struct Request: Codable, Equatable {
        var token: String
        var time: Double
    }

    struct Requests: Codable, Equatable {
        var format = 1
        /// ID of the Mac asked → the request.
        var asks: [String: Request] = [:]
    }

    /// What another Mac's folder holds. A scan reads a file again only when its date changed.
    struct Entry {
        var info: Info?
        var infoDate: Date?
        var requests: Requests?
        var requestsDate: Date?
        var historyDate: Date?
        var processDate: Date?
    }

    /// What a publish does with the process history copy (1–4 MB, so not sent every time).
    enum ProcessCopy {
        case keep
        case remove
        case write(Data)
    }

    static let infoFile = "info.json", historyFile = "history.bin", requestsFile = "requests.json",
               processFile = "process-history.sqlite.lzfse"

    func folder(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }

    // MARK: Writing (only in this Mac's folder)

    /// The histories first: a Mac that finds the new info.json mostly finds the new copies with it.
    func publish(_ info: Info, history: Data, processHistory: ProcessCopy = .keep) throws {
        let dir = folder(me)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try history.write(to: dir.appendingPathComponent(Self.historyFile), options: .atomic)
        switch processHistory {
        case .keep: break
        case .remove: try? FileManager.default.removeItem(at: dir.appendingPathComponent(Self.processFile))
        case .write(let data): try data.write(to: dir.appendingPathComponent(Self.processFile), options: .atomic)
        }
        try Self.encoder.encode(info).write(to: dir.appendingPathComponent(Self.infoFile), options: .atomic)
    }

    func writeRequests(_ r: Requests) throws {
        let dir = folder(me)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.encoder.encode(r).write(to: dir.appendingPathComponent(Self.requestsFile), options: .atomic)
    }

    func readOwnRequests() -> Requests? {
        (try? Data(contentsOf: folder(me).appendingPathComponent(Self.requestsFile))).flatMap { try? Self.decoder.decode(Requests.self, from: $0) }
    }

    /// Removes a Mac's folder: this one's when sharing is turned off, another's when you forget it.
    func remove(_ id: String) {
        try? FileManager.default.removeItem(at: folder(id))
    }

    // MARK: Reading

    /// The other Macs' folders. `known` is the last scan's result: files whose date didn't change
    /// aren't read again.
    func scan(known: [String: Entry]) -> [String: Entry] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles]) else { return [:] }
        var out: [String: Entry] = [:]
        for dir in items where (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let id = dir.lastPathComponent
            guard id != me else { continue }
            var e = known[id] ?? Entry()
            let infoDate = Self.date(dir, Self.infoFile)
            if infoDate != e.infoDate {
                e.infoDate = infoDate
                e.info = (try? Data(contentsOf: dir.appendingPathComponent(Self.infoFile))).flatMap { try? Self.decoder.decode(Info.self, from: $0) }
            }
            let requestsDate = Self.date(dir, Self.requestsFile)
            if requestsDate != e.requestsDate {
                e.requestsDate = requestsDate
                e.requests = (try? Data(contentsOf: dir.appendingPathComponent(Self.requestsFile))).flatMap { try? Self.decoder.decode(Requests.self, from: $0) }
            }
            let historyDate = Self.date(dir, Self.historyFile)
            if historyDate != e.historyDate {
                e.historyDate = historyDate
                // Brings a new copy down now (reading part of a file iCloud hasn't downloaded yet
                // downloads all of it), so showing that Mac doesn't wait for it.
                if let h = try? FileHandle(forReadingFrom: dir.appendingPathComponent(Self.historyFile)) {
                    _ = try? h.read(upToCount: 1)
                    try? h.close()
                }
            }
            // Process history is only read when Process History shows that Mac: no download now.
            e.processDate = Self.date(dir, Self.processFile)
            out[id] = e
        }
        return out
    }

    /// The date of one file, nil when there is none. On older macOS, iCloud Drive leaves a
    /// ".name.icloud" stand-in for a file it hasn't downloaded: that asks for the download (a
    /// later scan finds the file).
    private static func date(_ dir: URL, _ name: String) -> Date? {
        let url = dir.appendingPathComponent(name)
        if let d = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date { return d }
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".\(name).icloud").path) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
        return nil
    }

    func loadHistory(_ id: String) -> HistoryStore? {
        (try? Data(contentsOf: folder(id).appendingPathComponent(Self.historyFile))).flatMap(HistoryStore.init(copy:))
    }

    /// Another Mac's process history, from its copy; nil when it has none or it can't be read.
    /// Waits for iCloud to download it.
    func loadProcessHistory(_ id: String) -> ProcessTracker? {
        guard let packed = try? Data(contentsOf: folder(id).appendingPathComponent(Self.processFile)),
              let data = try? (packed as NSData).decompressed(using: .lzfse) as Data,
              let store = ProcessHistoryStore(copy: data) else { return nil }
        return ProcessTracker(copy: store)
    }

    // MARK: Decisions

    /// Another Mac's copy is older than this: looking at it asks for the latest.
    static let staleAfter: TimeInterval = 300
    /// An unanswered request this old shows as "no reply"; one older than `requestLifetime` is dropped.
    static let replyWait: TimeInterval = 300
    static let requestLifetime: TimeInterval = 3600

    /// Whether looking at a Mac now should ask it for the latest: its copy (with `processHistory`,
    /// its process history's) is older than `staleAfter` (or missing), and this Mac hasn't asked
    /// in the last `staleAfter`.
    static func shouldAsk(info: Info?, asked: Request?, now: Double, processHistory: Bool = false) -> Bool {
        if let t = processHistory ? info?.processHistory : info?.published, now - t < staleAfter { return false }
        if let asked, now - asked.time < staleAfter { return false }
        return true
    }

    /// Requests for this Mac that it hasn't answered yet: requester's ID → token. Requests older
    /// than `requestLifetime` (by the requester's clock) are ignored: that Mac stopped waiting.
    func newRequests(_ entries: [String: Entry], answered: [String: String], now: Double) -> [String: String] {
        var out: [String: String] = [:]
        for (id, e) in entries {
            guard let r = e.requests?.asks[me], answered[id] != r.token, now - r.time < Self.requestLifetime else { continue }
            out[id] = r.token
        }
        return out
    }

    enum Status: Equatable {
        case updated      // its copy is all there is
        case asking       // asked for the latest, waiting
        case noReply      // asked, no answer for `replyWait` (asleep, off or offline)
    }

    func status(_ info: Info, asked: Request?, now: Double) -> Status {
        guard let asked, info.answered[me] != asked.token, now - asked.time < Self.requestLifetime else { return .updated }
        return now - asked.time < Self.replyWait ? .asking : .noReply
    }

    /// What the menu says about a copy, after its time: how old it is, or that the latest is on its way.
    static func text(_ status: Status, published: Double, now: Double) -> String {
        let age = ago(now - published)
        switch status {
        case .updated: return age
        case .asking: return "updating…"
        case .noReply: return "no reply · \(age)"
        }
    }

    static func ago(_ seconds: Double) -> String {
        let s = max(0, seconds)
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        if s < 86400 { return "\(Int(s / 3600)) h ago" }
        let days = Int(s / 86400)
        return days == 1 ? "1 day ago" : "\(days) days ago"
    }

    /// Only the processes a viewer can show: the top 20 by each column.
    static func trim(_ snap: ProcSnapshot, perColumn: Int = 20) -> ProcSnapshot {
        var keep = Set<pid_t>()
        for s in ProcessListView.sortOrder {
            for r in snap.rows.sorted(by: { ProcessListView.key($0, s) > ProcessListView.key($1, s) }).prefix(perColumn) { keep.insert(r.pid) }
        }
        var t = snap
        t.rows = snap.rows.filter { keep.contains($0.pid) }
        return t
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return d
    }()
}

/// Shares this Mac's history with your other Macs that run MacMon Indicator, through a folder in
/// iCloud Drive (see ShareFolder), and shows theirs. Not live: each Mac publishes every hour,
/// before it sleeps or quits, and when another Mac asks, which it does when you look at that Mac
/// and its copy is older than 5 minutes. Off by default (Settings).
///
/// Process history goes with every publish except the hourly ones, which send it at most every
/// `processInterval`: it is bigger, and Process History asks for the latest when it shows a Mac.
///
/// Main thread only; files are read and written on a queue of its own. A change in the folder
/// (FSEvents) starts a scan, and so does a check every 5 minutes, in case an event is missed.
final class OtherMacs {
    static let publishInterval: TimeInterval = 3600
    /// The shortest time between two publishes for requests (or before sleep).
    static let minGap: TimeInterval = 120
    /// The hourly publish sends process history when the last copy is this old.
    static let processInterval: TimeInterval = 6 * 3600

    /// "iCloud Drive/MacMon Indicator", or nil while iCloud Drive is off. MACMON_INDICATOR_SHARE_DIR:
    /// another folder, for testing (two copies of the app with their own MACMON_INDICATOR_HISTORY_DIR
    /// and MACMON_DEBUG_MAC_ID act as two Macs).
    static var folder: URL? {
        if let v = ProcessInfo.processInfo.environment["MACMON_INDICATOR_SHARE_DIR"], !v.isEmpty {
            return URL(fileURLWithPath: v, isDirectory: true)
        }
        let drive = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.ubiquityIdentityToken != nil, FileManager.default.fileExists(atPath: drive.path) else { return nil }
        return drive.appendingPathComponent("MacMon Indicator", isDirectory: true)
    }

    struct Mac {
        let id: String
        let info: ShareFolder.Info
    }

    /// What to publish. `history` is HistoryStore.fileData(); `processes` nil: none scanned now
    /// (the last published ones are kept).
    struct Snapshot {
        var history: Data
        var latest: Sample?
        var hasBattery: Bool
        var processes: ProcSnapshot?
        var processHistory: ShareFolder.ProcessCopy = .keep
    }

    /// The other Macs that shared, by name.
    private(set) var macs: [Mac] = []
    /// Main queue: the Macs, their copies or what to show about them changed.
    var onChange: (() -> Void)?
    /// Main queue: gathers what to publish and calls `done` once, on the main queue. `quick`:
    /// right away, without a process scan (before sleep or quit). `processHistory`: with a copy
    /// of process history (or `.remove` while it's off); without, `.keep`.
    var snapshot: ((_ quick: Bool, _ processHistory: Bool, _ done: @escaping (Snapshot) -> Void) -> Void)?

    private let files: ShareFolder
    private let queue = DispatchQueue(label: "MacMonIndicator.otherMacs", qos: .utility)
    private var running = false
    private var entries: [String: ShareFolder.Entry] = [:]
    /// This Mac's own requests (its requests.json).
    private var asks = ShareFolder.Requests()
    /// Requests answered (and to answer with the next publish): requester's ID → token.
    private var answered: [String: String]
    private var lastPublish: Double
    private var lastProcesses: (snap: ProcSnapshot, time: Double)?
    /// The last publish with process history (a copy, or none while it's off), and when the copy
    /// in this Mac's folder was made (0: none).
    private var lastFull: Double
    private var processCopy: Double
    /// The next publish sends process history (an answer, or due).
    private var wantProcessHistory = false
    private var publishing = false
    private var publishWork: DispatchWorkItem?
    private var scanning = false, scanAgain = false, scannedOnce = false
    /// The hourly publish waits until then after start (see `start`).
    private var firstPublish: Double = 0
    private static let startDelay: TimeInterval = 15
    private var timer: Timer?
    private var stream: FSEventStreamRef?
    /// Copies of other Macs' history being shown, with the date of the file they came from.
    private var histories: [String: (date: Date?, store: HistoryStore)] = [:]

    // With the ID in the name, two copies of the app testing as two Macs keep theirs apart.
    private static let publishedKey = "otherMacsPublished-\(ThisMac.id)", answeredKey = "otherMacsAnswered-\(ThisMac.id)",
                       fullKey = "otherMacsPublishedProcesses-\(ThisMac.id)", processCopyKey = "otherMacsProcessCopy-\(ThisMac.id)"

    init(folder: URL) {
        files = ShareFolder(root: folder, me: ThisMac.id)
        let d = UserDefaults.standard
        lastPublish = d.double(forKey: Self.publishedKey)
        answered = d.dictionary(forKey: Self.answeredKey) as? [String: String] ?? [:]
        lastFull = d.double(forKey: Self.fullKey)
        processCopy = d.double(forKey: Self.processCopyKey)
    }

    deinit { stop(removeMine: false) } // the FSEvents stream points at this object

    func start() {
        guard !running else { return }
        running = true
        try? FileManager.default.createDirectory(at: files.root, withIntermediateDirectories: true)
        queue.async { [weak self, files] in
            let own = files.readOwnRequests()
            // Requests made since start (written after this read) are newer.
            DispatchQueue.main.async { if let own { self?.asks.asks.merge(own.asks) { mine, _ in mine } } }
        }
        watch()
        let t = Timer(timeInterval: 300, repeats: true) { [weak self] _ in self?.check() }
        t.tolerance = 60
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // The other Macs show right away; this one's copy waits for the first readings (up to 10 s
        // apart while the displays sleep, as after a quiet restart).
        firstPublish = Date().timeIntervalSince1970 + Self.startDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.startDelay + 1) { [weak self] in self?.check() }
        check()
    }

    /// Stops sharing; `removeMine`: also removes this Mac's copy, so your other Macs stop showing it.
    func stop(removeMine: Bool) {
        guard running else { return }
        running = false
        timer?.invalidate()
        timer = nil
        publishWork?.cancel()
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
        if removeMine {
            for k in [Self.publishedKey, Self.fullKey, Self.processCopyKey] { UserDefaults.standard.removeObject(forKey: k) }
            queue.async { [files] in files.remove(files.me) }
        }
    }

    /// Every 5 minutes, after wake and when the menu opens: look for changes FSEvents didn't
    /// report, then publish if an hour has passed (after the scan, which knows the requests to answer).
    func check() { scan() }

    // MARK: Publishing

    func publish() {
        guard running, !publishing, let snapshot else { return }
        publishing = true
        publishWork?.cancel()
        let full = wantProcessHistory
        snapshot(false, full) { [weak self] s in self?.write(s, full: full, wait: false) }
    }

    /// Before sleep or quit: right away, with process history, unless the last 2 minutes had such
    /// a publish. Waits for the files to be written; iCloud uploads them after wake if it has no
    /// time now.
    func publishNow() {
        guard running, !publishing, Date().timeIntervalSince1970 - lastFull >= Self.minGap, let snapshot else { return }
        publishing = true
        snapshot(true, true) { [weak self] s in self?.write(s, full: true, wait: true) }
    }

    private func write(_ s: Snapshot, full: Bool, wait: Bool) {
        publishing = false
        guard running else { return }
        let now = Date().timeIntervalSince1970
        if let p = s.processes { lastProcesses = (ShareFolder.trim(p), now) }
        if scannedOnce { answered = answered.filter { entries[$0.key] != nil } } // Macs that are gone
        // A copy that couldn't be made is asked for again with the next answer or after 6 hours.
        if full { wantProcessHistory = false }
        switch s.processHistory {
        case .keep: break
        case .remove: (lastFull, processCopy) = (now, 0)
        case .write: (lastFull, processCopy) = (now, now)
        }
        var info = ShareFolder.Info(id: files.me, name: ThisMac.name, model: ThisMac.model, app: TerminalServer.appVersion,
                                    published: now, hasBattery: s.hasBattery, latest: s.latest?.values ?? [:],
                                    processes: lastProcesses?.snap, processesTime: lastProcesses?.time, answered: answered)
        info.processHistory = processCopy > 0 ? processCopy : nil
        lastPublish = now
        let d = UserDefaults.standard
        d.set(now, forKey: Self.publishedKey)
        d.set(answered, forKey: Self.answeredKey)
        d.set(lastFull, forKey: Self.fullKey)
        d.set(processCopy, forKey: Self.processCopyKey)
        let job = { [files] in
            do { try files.publish(info, history: s.history, processHistory: s.processHistory) } catch {
                log.error("sharing with other Macs: \(error.localizedDescription, privacy: .public)")
            }
        }
        if wait { queue.sync(execute: job) } else { queue.async(execute: job) }
        // A request that came while this publish (without process history) was on its way.
        if wantProcessHistory { publishSoon() }
    }

    /// Answers requests from other Macs, with process history.
    private func answer(_ new: [String: String]) {
        guard !new.isEmpty else { return }
        answered.merge(new) { $1 }
        wantProcessHistory = true
        publishSoon()
    }

    /// Publishes now, or `minGap` after the last publish.
    private func publishSoon() {
        let wait = lastPublish + Self.minGap - Date().timeIntervalSince1970
        guard wait > 0 else { publish(); return }
        publishWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.publish() }
        publishWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    // MARK: Reading

    func scan() {
        guard running else { return }
        guard !scanning else { scanAgain = true; return }
        scanning = true
        let known = entries
        queue.async { [weak self, files] in
            let found = files.scan(known: known)
            DispatchQueue.main.async { self?.scanned(found) }
        }
    }

    private func scanned(_ found: [String: ShareFolder.Entry]) {
        scanning = false
        guard running else { return }
        entries = found
        scannedOnce = true
        macs = found.compactMap { id, e in e.info.map { Mac(id: id, info: $0) } }.sorted { a, b in
            let c = a.info.name.localizedStandardCompare(b.info.name)
            return c == .orderedSame ? a.id < b.id : c == .orderedAscending
        }
        histories = histories.filter { found[$0.key] != nil }
        let now = Date().timeIntervalSince1970
        answer(files.newRequests(found, answered: answered, now: now))
        // A no-op while answering's publish runs.
        if now - lastPublish >= Self.publishInterval, now >= firstPublish {
            if now - lastFull >= Self.processInterval { wantProcessHistory = true }
            publish()
        }
        onChange?()
        if scanAgain {
            scanAgain = false
            scan()
        }
    }

    /// Asks for the latest when you look at a Mac whose copy is old (see ShareFolder.shouldAsk):
    /// its charts, or with `processHistory` its process history.
    func lookedAt(_ id: String, processHistory: Bool = false) {
        guard running else { return }
        let now = Date().timeIntervalSince1970
        guard ShareFolder.shouldAsk(info: entries[id]?.info, asked: asks.asks[id], now: now, processHistory: processHistory) else { return }
        asks.asks[id] = ShareFolder.Request(token: UUID().uuidString, time: now)
        asks.asks = asks.asks.filter { now - $0.value.time < ShareFolder.requestLifetime }
        let r = asks
        queue.async { [files] in try? files.writeRequests(r) }
        onChange?()
        // "No reply" shows once the wait is over.
        DispatchQueue.main.asyncAfter(deadline: .now() + ShareFolder.replyWait + 1) { [weak self] in self?.onChange?() }
    }

    /// How old a Mac's copy is, or that the latest is on its way. With `processHistory`, its
    /// process history's copy; "" when it has none and none was asked for.
    func status(_ id: String, processHistory: Bool = false) -> String {
        guard let info = entries[id]?.info else { return "" }
        let now = Date().timeIntervalSince1970
        let status = files.status(info, asked: asks.asks[id], now: now)
        guard let t = processHistory ? info.processHistory : info.published else { return status == .asking ? "updating…" : "" }
        return ShareFolder.text(status, published: t, now: now)
    }

    /// Changes when a Mac publishes again, or its history file arrives after its info.json.
    func version(_ id: String) -> String {
        let e = entries[id]
        return "\(e?.info?.published ?? 0)/\(e?.historyDate?.timeIntervalSince1970 ?? 0)"
    }

    /// Changes when a Mac publishes process history again, or its file arrives after its info.json.
    func processVersion(_ id: String) -> String {
        let e = entries[id]
        return "\(e?.info?.processHistory ?? 0)/\(e?.processDate?.timeIntervalSince1970 ?? 0)"
    }

    /// Another Mac's process history, from its newest copy (nil: none), on the main queue. Not
    /// kept here: Process History keeps the one it shows.
    func processHistory(_ id: String, _ done: @escaping (ProcessTracker?) -> Void) {
        queue.async { [files] in
            let t = files.loadProcessHistory(id)
            DispatchQueue.main.async { done(t) }
        }
    }

    /// A copy of another Mac's history, from its newest file. Main queue.
    func history(_ id: String, _ done: @escaping (HistoryStore?) -> Void) {
        let date = entries[id]?.historyDate
        if let c = histories[id], c.date == date { done(c.store); return }
        queue.async { [weak self, files] in
            let h = files.loadHistory(id)
            DispatchQueue.main.async {
                if let h { self?.histories[id] = (date, h) }
                done(h)
            }
        }
    }

    /// Frees the copies nothing shows (when the menu closes).
    func keepHistories(_ ids: Set<String>) {
        histories = histories.filter { ids.contains($0.key) }
    }

    /// Removes another Mac's copy from iCloud Drive. A Mac that still shares puts it back with its next publish.
    func forget(_ id: String) {
        entries[id] = nil
        histories[id] = nil
        macs.removeAll { $0.id == id }
        queue.async { [files] in files.remove(id) }
        onChange?()
    }

    // MARK: FSEvents

    private func watch() {
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<OtherMacs>.fromOpaque(info).takeUnretainedValue().scan()
        }
        // 2 s latency: iCloud writes a file in steps; one scan after it settles.
        guard let s = FSEventStreamCreate(nil, callback, &ctx, [files.root.path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else { return }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
    }
}
