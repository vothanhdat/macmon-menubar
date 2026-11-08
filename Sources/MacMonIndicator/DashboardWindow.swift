import AppKit

/// The dashboard in a normal, resizable window. Charts and the process list grow with it.
/// It remembers its size and position. Created when opened, released when closed.
///
/// It only costs anything while it can be seen: `isVisible` is false while it is minimized,
/// fully covered or on another Space, and the app stops updating it then.
final class DashboardWindowController: NSWindowController, NSWindowDelegate {
    let dashboard: Dashboard
    var onClose: (() -> Void)?
    /// Called when the window starts or stops being visible on screen.
    var onVisibilityChange: ((Bool) -> Void)?
    private(set) var isVisible = false
    private var layoutWork: DispatchWorkItem?
    private static let frameName = "Dashboard"

    init(history: HistoryStore, latest: Sample?, hasBattery: Bool) {
        dashboard = Dashboard(history: history, latest: latest, hasBattery: hasBattery, inWindow: true)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: dashboard.minWindowSize),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "MacMon Indicator"
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        let content = FlippedView()
        content.addSubview(dashboard.windowView)
        w.contentView = content
        super.init(window: w)
        w.delegate = self
        dashboard.onReflow = { [weak self] in self?.relayout() }
        updateMinSize()
        if !w.setFrameUsingName(Self.frameName) { w.center() }
        w.setFrameAutosaveName(Self.frameName)
        relayout()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Chart settings changed: show the new charts, at least at their new minimum size.
    func settingsChanged() {
        dashboard.loadSettings()
    }

    private func updateMinSize() {
        guard let w = window else { return }
        let min = dashboard.minWindowSize
        w.contentMinSize = min
        let size = w.contentRect(forFrameRect: w.frame).size
        if size.width < min.width || size.height < min.height {
            w.setContentSize(NSSize(width: max(size.width, min.width), height: max(size.height, min.height)))
        }
    }

    private func relayout() {
        guard let w = window else { return }
        updateMinSize()
        dashboard.layout(windowSize: w.contentRect(forFrameRect: w.frame).size)
    }

    // MARK: - NSWindowDelegate

    /// While the edge is being dragged the dashboard keeps its layout (new space shows the window
    /// background, and shrinking clips it), and is laid out and redrawn when the drag pauses or
    /// ends. Redrawing on every frame of the drag would cost about 10% of a core for nothing.
    func windowDidResize(_ notification: Notification) {
        guard let w = window else { return }
        layoutWork?.cancel()
        guard w.inLiveResize else { relayout(); return }
        let work = DispatchWorkItem { [weak self] in self?.relayout() }
        layoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        layoutWork?.cancel()
        relayout()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) { updateVisible() }

    func windowWillClose(_ notification: Notification) {
        layoutWork?.cancel()
        if isVisible { isVisible = false; onVisibilityChange?(false) }
        onClose?()
    }

    func updateVisible() {
        guard let w = window else { return }
        let v = w.isVisible && w.occlusionState.contains(.visible)
        guard v != isVisible else { return }
        isVisible = v
        onVisibilityChange?(v)
    }
}
