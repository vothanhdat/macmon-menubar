import Foundation
import UserNotifications

/// Notifications about programs using far more CPU than usual (ProcessTracker.Unusual): one per
/// program per day. Off unless turned on in Settings; nothing here runs before that. Main queue.
final class UsageAlerts: NSObject, UNUserNotificationCenterDelegate {
    static let shared = UsageAlerts()
    /// A notification was clicked.
    var onOpen: (() -> Void)?

    private static let dayKey = "unusualNotifiedDay"
    private static let pathsKey = "unusualNotified"

    /// Notifications need the app's bundle (not `swift run` or the tests).
    static var available: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }

    /// Asks macOS for permission (the first time, macOS asks the user). `done` on the main queue.
    func enable(_ done: @escaping (Bool) -> Void) {
        guard Self.available else { done(false); return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { ok, error in
            if let error { log.error("notifications: \(error.localizedDescription, privacy: .public)") }
            DispatchQueue.main.async { done(ok) }
        }
    }

    /// Clicks on notifications delivered by this or an earlier run come here.
    func listen() {
        guard Self.available else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    /// The programs in `unusual` that haven't been told about on the day starting at `day`, which
    /// are then remembered as told (also across restarts).
    static func fresh(_ unusual: [ProcessTracker.Unusual], day: Int, defaults d: UserDefaults = .standard) -> [ProcessTracker.Unusual] {
        var told = d.integer(forKey: dayKey) == day ? Set(d.stringArray(forKey: pathsKey) ?? []) : []
        let new = unusual.filter { !told.contains($0.path) }
        guard !new.isEmpty else { return [] }
        told.formUnion(new.map(\.path))
        d.set(day, forKey: dayKey)
        d.set(told.sorted(), forKey: pathsKey)
        return new
    }

    static func text(_ u: ProcessTracker.Unusual) -> (title: String, body: String) {
        ("\(ProcKey.name(u.path)) is using more CPU than usual",
         "\(Fmt.duration(u.today)) of CPU time today. It usually uses about \(Fmt.duration(u.usual)) a day.")
    }

    /// Notifies about the programs not told about yet today.
    func post(_ unusual: [ProcessTracker.Unusual], now: Date = Date()) {
        guard Self.available, !unusual.isEmpty else { return }
        let day = Int(Calendar.current.startOfDay(for: now).timeIntervalSince1970)
        for u in Self.fresh(unusual, day: day) {
            let content = UNMutableNotificationContent()
            (content.title, content.body) = Self.text(u)
            // One per program per day: a later one for the same program would replace it.
            let request = UNNotificationRequest(identifier: "unusual-\(day)-\(u.path)", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { error in
                if let error { log.error("notification: \(error.localizedDescription, privacy: .public)") }
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { self.onOpen?() }
        completionHandler()
    }

    /// Shown also while the app is in front (its windows are).
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
