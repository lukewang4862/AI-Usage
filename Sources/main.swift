import AppKit
import Foundation

func countdown(_ reset: Date, now: Date = Date()) -> String {
    let minutes = max(0, Int(reset.timeIntervalSince(now) / 60))
    return String(format: "%dD %02d:%02d", minutes / 1440, (minutes % 1440) / 60, minutes % 60)
}

struct Credit {
    let id: String
    let expires: Date?
}

struct Usage {
    let remaining: Double
    let reset: Date?
    let duration: Int
    let creditCount: Int?
    let credits: [Credit]
    let eligible: Bool

    static func parse(_ data: [String: Any]) throws -> Usage {
        let buckets = data["rateLimitsByLimitId"] as? [String: [String: Any]]
        guard let bucket = buckets?["codex"] ?? data["rateLimits"] as? [String: Any] else {
            throw WidgetError.message("账户暂未返回额度数据")
        }
        let windows = [bucket["primary"], bucket["secondary"]].compactMap { $0 as? [String: Any] }
            .filter { $0["usedPercent"] is NSNumber }
        // Show the most depleted window; keep its reset time paired with that window.
        guard let chosen = windows.max(by: { (($0["usedPercent"] as? NSNumber)?.doubleValue ?? 0) < (($1["usedPercent"] as? NSNumber)?.doubleValue ?? 0) }),
              let used = (chosen["usedPercent"] as? NSNumber)?.doubleValue else { throw WidgetError.message("暂无可用额度窗口") }
        let resetInfo = data["rateLimitResetCredits"] as? [String: Any]
        let credits = (resetInfo?["credits"] as? [[String: Any]] ?? []).compactMap { row -> Credit? in
            guard let id = row["id"] as? String, row["status"] as? String == "available" else { return nil }
            let expires = (row["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return Credit(id: id, expires: expires)
        }.sorted { ($0.expires ?? .distantFuture) < ($1.expires ?? .distantFuture) }
        return Usage(remaining: max(0, min(100, 100 - used)),
                     reset: (chosen["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
                     duration: chosen["windowDurationMins"] as? Int ?? 0,
                     creditCount: resetInfo?["availableCount"] as? Int,
                     credits: credits,
                     eligible: windows.contains { (($0["usedPercent"] as? NSNumber)?.doubleValue ?? 0) >= 90 })
    }
}

enum WidgetError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(s) = self { return s }; return nil }
}

// A separate local app-server process uses Codex's existing managed login.
// No tokens are read, copied, logged or stored by this application.
final class CodexBridge {
    private let queue = DispatchQueue(label: "local.codex.usage.rpc")
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var nextID = 0
    private let lock = NSLock()
    private var stopped = false

    func request(_ method: String, params: [String: Any] = [:], completion: @escaping (Result<[String: Any], Error>) -> Void) {
        queue.async {
            do {
                self.lock.lock(); let stopped = self.stopped; self.lock.unlock()
                if stopped { throw WidgetError.message("应用已退出") }
                try self.connect()
                let result = try self.call(method, params: params)
                DispatchQueue.main.async { completion(.success(result)) }
            } catch {
                self.disconnect()
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private func connect() throws {
        if process?.isRunning == true { return }
        let candidates = ["/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex", "/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex", "/Applications/ChatGPT.app/Contents/Resources/codex", "/Applications/Codex.app/Contents/Resources/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw WidgetError.message("未找到 Codex，请先安装并登录 Codex")
        }
        let p = Process(), stdin = Pipe(), stdout = Pipe()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["app-server", "--stdio"]
        p.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        p.standardInput = stdin; p.standardOutput = stdout; p.standardError = FileHandle.nullDevice
        try p.run()
        lock.lock(); process = p; lock.unlock()
        input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading; buffer = Data()
        _ = try call("initialize", params: ["clientInfo": ["name": "codex_usage_widget", "title": "AI Usage", "version": "0.1.0"]])
        try write(["method": "initialized", "params": [:]])
    }

    private func write(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object); data.append(10)
        guard let input else { throw WidgetError.message("Codex 连接已断开") }
        try input.write(contentsOf: data)
    }

    private func call(_ method: String, params: [String: Any]) throws -> [String: Any] {
        nextID += 1; let id = nextID
        try write(["id": id, "method": method, "params": params])
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            if let newline = buffer.firstIndex(of: 10) {
                let line = buffer[..<newline]; buffer.removeSubrange(...newline)
                guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                if object["id"] as? Int != id { continue }
                if let error = object["error"] as? [String: Any] {
                    throw WidgetError.message(error["message"] as? String ?? "Codex 请求失败")
                }
                return object["result"] as? [String: Any] ?? [:]
            }
            guard let output else { throw WidgetError.message("Codex 连接已断开") }
            var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let result = poll(&descriptor, 1, 200)
            if result < 0 { throw WidgetError.message("无法读取 Codex 数据") }
            if result > 0 {
                var bytes = [UInt8](repeating: 0, count: 16384)
                let count = Darwin.read(output.fileDescriptor, &bytes, bytes.count)
                if count <= 0 { throw WidgetError.message("Codex 连接已结束，请稍后重试") }
                buffer.append(contentsOf: bytes.prefix(count))
            }
        }
        throw WidgetError.message("读取超时，稍后将自动重试")
    }

    private func disconnect() {
        try? input?.close(); try? output?.close(); input = nil; output = nil
        lock.lock(); let p = process; process = nil; lock.unlock()
        if p?.isRunning == true { p?.terminate() }
        buffer = Data()
    }

    func stop() {
        lock.lock(); stopped = true; let p = process; lock.unlock()
        if p?.isRunning == true { p?.terminate() }
    }
}

enum Edge: String { case left, right }

enum Provider: String, CaseIterable {
    case codex = "Codex", grok = "Grok", muse = "Muse"
    var enabled: Bool { UserDefaults.standard.object(forKey: "show" + rawValue) as? Bool ?? true }
}

enum Layout {
    static var rowCount = 3
    static let cardWidth: CGFloat = 240
    static let handleWidth: CGFloat = 44 * 0.7
    static var cardHeight: CGFloat { CGFloat(max(1, rowCount)) * 92 + 16 }
    static var handleHeight: CGFloat { CGFloat(max(1, rowCount)) * 62 + 22 }

    // Hysteresis keeps the widget from flickering in and out of the magnetic zone.
    static let snapDistance: CGFloat = 64
    static let releaseDistance: CGFloat = 104
    static func magneticEdge(for frame: NSRect, in screen: NSRect, retaining edge: Edge?) -> Edge? {
        let left = frame.minX - screen.minX
        let right = screen.maxX - frame.maxX
        if let edge, (edge == .left ? left : right) <= releaseDistance { return edge }
        if min(left, right) <= snapDistance { return left <= right ? .left : .right }
        return nil
    }

    static func clamp(_ frame: NSRect, to screen: NSRect) -> NSRect {
        var r = frame
        r.origin.x = max(screen.minX, min(r.minX, screen.maxX - r.width))
        r.origin.y = max(screen.minY, min(r.minY, screen.maxY - r.height))
        return r
    }
    static func docked(edge: Edge, collapsed: Bool, centerY: CGFloat, screen: NSRect) -> NSRect {
        let size = collapsed ? NSSize(width: handleWidth, height: handleHeight) : NSSize(width: cardWidth + handleWidth, height: cardHeight)
        return clamp(NSRect(x: edge == .left ? screen.minX : screen.maxX - size.width,
                            y: centerY - size.height / 2, width: size.width, height: size.height), to: screen)
    }
}

final class WidgetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class WidgetView: NSView {
    weak var controller: WidgetController?
    private var tracking: NSTrackingArea?
    override var acceptsFirstResponder: Bool { true }
    // Handle the initial press even while another application's window is active.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { controller?.entered() }
    override func mouseExited(with event: NSEvent) { controller?.scheduleCollapse() }
    override func mouseDown(with event: NSEvent) { controller?.mouseDown(event) }
    override func mouseDragged(with event: NSEvent) { controller?.mouseDragged(event) }
    override func mouseUp(with event: NSEvent) { controller?.mouseUp(event) }
    override func rightMouseDown(with event: NSEvent) { controller?.showContextMenu(event) }

    private func label(_ text: String, _ rect: NSRect, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) {
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        (text as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: paragraph])
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let c = controller else { return }
        if c.collapsed { drawHandle(bounds); return }
        let ox: CGFloat = c.edge == .left ? Layout.handleWidth : 0
        let card = NSRect(x: ox + 1, y: 1, width: Layout.cardWidth-2, height: bounds.height-2)
        NSColor(calibratedWhite: 0.98, alpha: 0.97).setFill()
        NSBezierPath(roundedRect: card, xRadius: 18, yRadius: 18).fill()
        let ink = NSColor(calibratedWhite: 0.12, alpha: 1)
        let secondary = NSColor(calibratedWhite: 0.40, alpha: 1)
        if c.providers.isEmpty {
            label("Settings…", NSRect(x: ox+20, y: 42, width: 200, height: 25), size: 16, color: secondary)
        }
        for (index, provider) in c.providers.enumerated() {
            let y = bounds.height - 8 - CGFloat(index+1)*92
            let data = c.data(provider), color = WidgetController.color(data.0)
            label(provider.rawValue + (data.2 == nil ? "" : " !"), NSRect(x: ox+14, y: y+59, width: 85, height: 24), size: 16, weight: .semibold, color: ink)
            label(data.0.map { "\(Int($0.rounded()))%" } ?? "—", NSRect(x: ox+146, y: y+56, width: 80, height: 29), size: 23, weight: .semibold, color: data.0 == nil ? secondary : color)
            let track = NSRect(x: ox+20, y: y+39, width: 200, height: 8)
            NSColor(calibratedRed: 0.87, green: 0.90, blue: 0.94, alpha: 1).setFill()
            NSBezierPath(roundedRect: track, xRadius: 4, yRadius: 4).fill()
            if let remaining = data.0, remaining > 0 {
                let fill = NSRect(x: track.minX, y: track.minY, width: track.width * CGFloat(remaining/100), height: track.height)
                NSGradient(starting: color.blended(withFraction: 0.18, of: .white) ?? color, ending: color)?.draw(in: NSBezierPath(roundedRect: fill, xRadius: 4, yRadius: 4), angle: 0)
            }
            label(data.1.map { countdown($0) } ?? "—", NSRect(x: ox+14, y: y+12, width: 137, height: 21), size: 15, weight: .medium, color: secondary)
            if provider == .codex {
                let r = c.creditRect
                NSColor.white.setFill(); NSBezierPath(ovalIn: r).fill()
                NSColor(calibratedWhite: 0.85, alpha: 1).setStroke(); NSBezierPath(ovalIn: r).stroke()
                label(c.redeeming ? "…" : c.usage?.creditCount.map(String.init) ?? "—", NSRect(x: r.minX, y: r.minY+3, width: r.width, height: 21), size: 15, weight: .medium, color: secondary)
            }
            if index < c.providers.count-1 {
                NSColor(calibratedWhite: 0.87, alpha: 1).setFill(); NSRect(x: ox+18, y: y, width: 204, height: 0.5).fill()
            }
        }
        if let edge = c.edge {
            drawHandle(NSRect(x: edge == .left ? 0 : Layout.cardWidth, y: (bounds.height-Layout.handleHeight)/2, width: Layout.handleWidth, height: Layout.handleHeight))
        }
    }

    private func drawHandle(_ rect: NSRect) {
        guard let c = controller else { return }
        NSColor(calibratedWhite: 0.98, alpha: 0.97).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
        if c.dragging {
            NSColor.systemBlue.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
            NSColor.systemBlue.withAlphaComponent(0.7).setStroke()
            let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9)
            outline.lineWidth = 1.5; outline.stroke()
        }
        for (index, provider) in c.providers.enumerated() {
            let data = c.data(provider)
            let base = rect.maxY - CGFloat(index+1)*62 - 2
            label(String(provider.rawValue.prefix(1)) + (data.2 == nil ? "" : "!"), NSRect(x: rect.minX, y: base+38, width: rect.width, height: 18), size: 14, weight: .semibold, color: .darkGray)
            WidgetController.color(data.0).setFill()
            NSBezierPath(roundedRect: NSRect(x: rect.midX-9, y: base+25, width: 18, height: 5), xRadius: 2.5, yRadius: 2.5).fill()
            let percentage = data.0.map { "\(Int($0.rounded()))%" } ?? "—"
            var fontSize: CGFloat = 13
            while fontSize > 8 && (percentage as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .semibold)]).width > rect.width - 0.5 { fontSize -= 0.25 }
            label(percentage, NSRect(x: rect.minX, y: base+3, width: rect.width, height: 19), size: fontSize, weight: .semibold, color: .darkGray)
        }
        label(c.edge == .left ? "›" : "‹", NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 19), size: 17, color: .gray)
    }
}

final class WidgetController: NSObject, NSMenuDelegate {
    let panel: WidgetPanel
    let view = WidgetView()
    let bridge = CodexBridge()
    let grokBridge = GrokBridge()
    let museBridge = MuseBridge()
    var museUsage: GrokUsage?
    var lastMuseError: String?
    private var fetchingMuse = false
    private var settingsWindow: NSWindow?
    var providers: [Provider] { Provider.allCases.filter { $0.enabled } }
    var creditRect: NSRect {
        guard let index = providers.firstIndex(of: .codex) else { return .zero }
        return NSRect(x: (edge == .left ? Layout.handleWidth : 0) + 192, y: Layout.cardHeight - 8 - CGFloat(index+1)*92 + 8, width: 28, height: 28)
    }
    func data(_ provider: Provider) -> (Double?, Date?, String?) {
        switch provider {
        case .codex: return (usage?.remaining, usage?.reset, lastError)
        case .grok: return (grokUsage?.remaining, grokUsage?.reset, lastGrokError)
        case .muse: return (museUsage?.remaining, museUsage?.reset, lastMuseError)
        }
    }
    var grokUsage: GrokUsage?
    var lastGrokError: String?
    private var fetchingGrok = false
    var usage: Usage?
    var lastError: String?
    var edge: Edge?
    var collapsed = false
    var redeeming = false
    private var fetching = false
    private var menuOpen = false
    private(set) var dragging = false
    private var pressPoint = NSPoint.zero
    private var pressOrigin = NSPoint.zero
    private var pressLocal = NSPoint.zero
    private var anchorY: CGFloat = 120
    private var screenFrame = NSRect.zero
    private var refreshTimer: Timer?
    private var countdownTimer: Timer?
    private var hoverTimer: Timer?
    private var collapseTimer: Timer?
    private var pendingRedemption: (credit: String, key: String)?
    private var lastUpdated: Date?

    var usageColor: NSColor { Self.color(usage?.remaining) }
    var grokColor: NSColor { Self.color(grokUsage?.remaining) }
    static func color(_ remaining: Double?) -> NSColor {
        guard let remaining else { return .systemGray }
        let red = NSColor(calibratedRed: 0.98, green: 0.28, blue: 0.20, alpha: 1)
        let yellow = NSColor(calibratedRed: 0.97, green: 0.72, blue: 0.15, alpha: 1)
        let green = NSColor(calibratedRed: 0.20, green: 0.76, blue: 0.43, alpha: 1)
        if remaining <= 50 { return red.blended(withFraction: remaining / 50, of: yellow) ?? red }
        return yellow.blended(withFraction: (remaining - 50) / 50, of: green) ?? green
    }

    init(preview: Bool = false) {
        panel = WidgetPanel(contentRect: NSRect(x: 0, y: 0, width: 180, height: 180), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = false; panel.acceptsMouseMovedEvents = true
        panel.title = "AI Usage"
        panel.appearance = NSAppearance(named: .aqua)
        view.controller = self; panel.contentView = view
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel("AI Usage 额度卡片")
        if let credit = UserDefaults.standard.string(forKey: "pendingCredit"), let key = UserDefaults.standard.string(forKey: "pendingKey") {
            pendingRedemption = (credit, key)
        }
        Layout.rowCount = providers.count
        museBridge.onUpdate = { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value): self.museUsage = value; self.lastMuseError = nil
            case .failure(let error): self.museUsage = nil; self.lastMuseError = error.localizedDescription
            }
            self.updateTooltip(); self.view.needsDisplay = true
        }
        restore()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        if preview { return }
        panel.orderFrontRegardless()
        refresh()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.view.needsDisplay = true }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        // Window resizing can miss a tracking-area exit; keep hover behavior reliable.
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self, self.edge != nil, !self.dragging, !self.menuOpen, !self.redeeming else { return }
            if self.panel.frame.contains(NSEvent.mouseLocation) {
                self.entered()
            } else if !self.collapsed && self.collapseTimer?.isValid != true {
                self.scheduleCollapse()
            }
        }
    }

    func dateString(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MM/dd HH:mm"; return f.string(from: date)
    }

    private func restore() {
        let defaults = UserDefaults.standard
        let screens = NSScreen.screens
        let initial = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var frame = NSRect(x: initial.maxX - 264, y: initial.maxY - Layout.cardHeight - 60, width: Layout.cardWidth, height: Layout.cardHeight)
        if defaults.object(forKey: "x") != nil {
            frame.origin = NSPoint(x: defaults.double(forKey: "x"), y: defaults.double(forKey: "y"))
        }
        screenFrame = screens.first(where: { $0.frame.intersects(frame) })?.frame ?? initial
        edge = defaults.string(forKey: "edge").flatMap(Edge.init(rawValue:))
        anchorY = defaults.object(forKey: "anchorY") != nil ? defaults.double(forKey: "anchorY") : frame.midY
        collapsed = edge != nil
        panel.setFrame(edge.map { Layout.docked(edge: $0, collapsed: collapsed, centerY: anchorY, screen: screenFrame) } ?? Layout.clamp(frame, to: screenFrame), display: true)
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(panel.frame.minX, forKey: "x"); d.set(panel.frame.minY, forKey: "y")
        d.set(edge?.rawValue, forKey: "edge"); d.set(anchorY, forKey: "anchorY")
    }

    func refresh() {
        if Provider.grok.enabled { refreshGrok() }
        if Provider.muse.enabled && !fetchingMuse {
            fetchingMuse = true
            museBridge.read { [weak self] _ in self?.fetchingMuse = false }
        }
        guard Provider.codex.enabled, !fetching, !redeeming else { return }
        fetching = true
        bridge.request("account/rateLimits/read") { [weak self] result in
            guard let self else { return }; self.fetching = false
            do {
                self.usage = try Usage.parse(result.get()); self.lastError = nil; self.lastUpdated = Date()
            } catch { self.usage = nil; self.lastError = error.localizedDescription }
            self.updateTooltip(); self.view.needsDisplay = true
        }
    }

    private func refreshGrok() {
        guard !fetchingGrok else { return }
        fetchingGrok = true
        grokBridge.read { [weak self] result in
            guard let self else { return }; self.fetchingGrok = false
            switch result {
            case .success(let value): self.grokUsage = value; self.lastGrokError = nil
            case .failure(let error): self.grokUsage = nil; self.lastGrokError = error.localizedDescription
            }
            self.updateTooltip(); self.view.needsDisplay = true
        }
    }
    private func updateTooltip() {
        var messages = providers.map { provider -> String in
            let value = data(provider)
            return provider.rawValue + (value.0.map { " 剩余 \(Int($0.rounded()))%" } ?? " 未连接") + (value.2.map { "：" + $0 } ?? "")
        }
        messages.append("倒计时：天D 小时:分钟；右键打开 Settings、刷新或退出")
        view.toolTip = messages.joined(separator: "\n")
        view.setAccessibilityValue(messages.joined(separator: "，"))
    }

    @objc private func woke() { screensChanged(); refresh() }
    @objc private func screensChanged() {
        screenFrame = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: panel.frame.midX, y: panel.frame.midY)) })?.frame ?? NSScreen.main?.frame ?? screenFrame
        if let edge { panel.setFrame(Layout.docked(edge: edge, collapsed: collapsed, centerY: anchorY, screen: screenFrame), display: true) }
        else { panel.setFrame(Layout.clamp(panel.frame, to: screenFrame), display: true) }
        save()
    }

    func entered() {
        collapseTimer?.invalidate()
        guard !dragging, collapsed, let edge else { return }
        collapsed = false
        panel.setFrame(Layout.docked(edge: edge, collapsed: false, centerY: anchorY, screen: screenFrame), display: true)
        view.needsDisplay = true
    }

    func scheduleCollapse() {
        collapseTimer?.invalidate()
        guard edge != nil, !collapsed else { return }
        collapseTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            guard let self, let edge = self.edge, !self.dragging, !self.menuOpen, !self.redeeming else { return }
            if self.panel.frame.contains(NSEvent.mouseLocation) { return }
            self.collapsed = true
            self.panel.setFrame(Layout.docked(edge: edge, collapsed: true, centerY: self.anchorY, screen: self.screenFrame), display: true)
            self.view.needsDisplay = true; self.save()
        }
    }

    func mouseDown(_ event: NSEvent) {
        let screenPoint = panel.convertPoint(toScreen: event.locationInWindow)
        if collapsed { entered() }
        collapseTimer?.invalidate(); dragging = false
        pressPoint = screenPoint; pressOrigin = panel.frame.origin
        pressLocal = panel.convertPoint(fromScreen: screenPoint)
    }

    func mouseDragged(_ event: NSEvent) {
        let p = panel.convertPoint(toScreen: event.locationInWindow)
        if !dragging && hypot(p.x - pressPoint.x, p.y - pressPoint.y) < 4 { return }
        if !dragging && (edge != nil || collapsed) {
            let oldCenter = NSPoint(x: panel.frame.minX + (edge == .left ? Layout.handleWidth : 0) + Layout.cardWidth/2, y: panel.frame.midY)
            edge = nil; collapsed = false
            pressOrigin = NSPoint(x: oldCenter.x - Layout.cardWidth/2, y: oldCenter.y - Layout.cardHeight/2)
        }
        dragging = true
        let nextScreen = NSScreen.screens.first(where: { $0.frame.contains(p) })?.frame ?? screenFrame
        if nextScreen != screenFrame { edge = nil }
        screenFrame = nextScreen
        // Use the unsnapped drag position, so a snapped window still pulls away naturally.
        let frame = NSRect(x: pressOrigin.x + p.x - pressPoint.x, y: pressOrigin.y + p.y - pressPoint.y, width: Layout.cardWidth, height: Layout.cardHeight)
        edge = Layout.magneticEdge(for: frame, in: screenFrame, retaining: edge)
        collapsed = false
        anchorY = frame.midY
        if let edge {
            panel.setFrame(Layout.docked(edge: edge, collapsed: false, centerY: anchorY, screen: screenFrame), display: true)
        } else {
            panel.setFrame(Layout.clamp(frame, to: screenFrame), display: true)
        }
        view.needsDisplay = true
    }

    func mouseUp(_ event: NSEvent) {
        if dragging {
            dragging = false
            if let edge {
                anchorY = panel.frame.midY
                panel.setFrame(Layout.docked(edge: edge, collapsed: false, centerY: anchorY, screen: screenFrame), display: true)
                scheduleCollapse()
            }
            save(); view.needsDisplay = true
        } else {
            if providers.contains(.codex) && creditRect.contains(pressLocal) { showCredits() }
            else if providers.isEmpty { showSettings() }
        }
    }

    func showContextMenu(_ event: NSEvent) {
        let menu = NSMenu(); menu.delegate = self
        let refreshItem = menu.addItem(withTitle: "刷新数据", action: #selector(refreshAction), keyEquivalent: ""); refreshItem.target = self
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ""); settings.target = self
        menu.addItem(.separator())
        let item = menu.addItem(withTitle: "退出 App", action: #selector(quit), keyEquivalent: "")
        item.target = self
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    private func showCredits() {
        guard !redeeming else { return }
        let menu = NSMenu(); menu.delegate = self; menu.autoenablesItems = false
        let heading = menu.addItem(withTitle: "选择重置券", action: nil, keyEquivalent: ""); heading.isEnabled = false
        menu.addItem(.separator())
        let fresh = lastUpdated.map { Date().timeIntervalSince($0) < 120 } ?? false
        if let usage {
            if usage.credits.isEmpty {
                let text = (usage.creditCount ?? 0) > 0 ? "有 \(usage.creditCount!) 张券，详情暂不可用" : usage.creditCount == nil ? "暂未取得重置券信息" : "暂无可用重置券"
                let item = menu.addItem(withTitle: text, action: nil, keyEquivalent: ""); item.isEnabled = false
            }
            for (index, credit) in usage.credits.enumerated() {
                let expiry = credit.expires.map { "\(dateString($0)) 到期" } ?? "未提供到期时间"
                let item = menu.addItem(withTitle: "重置券 \(index + 1)    \(expiry)", action: #selector(selectCredit(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = credit.id
                item.isEnabled = usage.eligible && fresh && lastError == nil && (credit.expires ?? .distantFuture) > Date()
            }
            if !usage.eligible {
                menu.addItem(.separator())
                let item = menu.addItem(withTitle: "剩余 ≤ 10% 时可使用", action: nil, keyEquivalent: ""); item.isEnabled = false
            }
        }
        if lastError != nil || !fresh {
            let item = menu.addItem(withTitle: "数据尚未更新，请先刷新", action: nil, keyEquivalent: ""); item.isEnabled = false
        }
        menu.addItem(.separator())
        let refresh = menu.addItem(withTitle: "刷新数据", action: #selector(refreshAction), keyEquivalent: ""); refresh.target = self
        menu.popUp(positioning: nil, at: NSPoint(x: creditRect.midX, y: creditRect.minY), in: view)
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 245), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "AI Usage · Settings"; w.isReleasedWhenClosed = false
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 245))
            let heading = NSTextField(labelWithString: "显示的服务")
            heading.font = .systemFont(ofSize: 16, weight: .semibold); heading.frame = NSRect(x: 24, y: 199, width: 260, height: 25); content.addSubview(heading)
            for (index, provider) in Provider.allCases.enumerated() {
                let button = NSButton(checkboxWithTitle: provider.rawValue, target: self, action: #selector(toggleProvider(_:)))
                button.tag = index; button.state = provider.enabled ? .on : .off
                button.frame = NSRect(x: 24, y: 164-CGFloat(index)*34, width: 140, height: 26)
                content.addSubview(button)
            }
            let login = NSButton(title: "登录 Muse…", target: self, action: #selector(loginMuse))
            login.bezelStyle = .rounded; login.frame = NSRect(x: 176, y: 94, width: 122, height: 30); content.addSubview(login)
            let hint = NSTextField(wrappingLabelWithString: "勾选后立即生效，收纳手柄同步变化。\nMuse 首次使用需要独立登录。")
            hint.font = .systemFont(ofSize: 12); hint.textColor = .secondaryLabelColor; hint.frame = NSRect(x: 24, y: 23, width: 275, height: 48); content.addSubview(hint)
            w.contentView = content; w.center(); settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true); settingsWindow?.makeKeyAndOrderFront(nil)
    }
    @objc private func loginMuse() { museBridge.showLogin() }
    @objc private func toggleProvider(_ button: NSButton) {
        let provider = Provider.allCases[button.tag]
        UserDefaults.standard.set(button.state == .on, forKey: "show" + provider.rawValue)
        Layout.rowCount = providers.count
        if let edge {
            panel.setFrame(Layout.docked(edge: edge, collapsed: collapsed, centerY: anchorY, screen: screenFrame), display: true)
        } else {
            let old = panel.frame
            panel.setFrame(Layout.clamp(NSRect(x: old.minX, y: old.maxY-Layout.cardHeight, width: Layout.cardWidth, height: Layout.cardHeight), to: screenFrame), display: true)
        }
        view.needsDisplay = true; updateTooltip(); save(); refresh()
    }

    @objc private func refreshAction() { refresh() }
    @objc private func selectCredit(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        // Defer until the native menu has completed its tracking loop.
        DispatchQueue.main.async { [weak self] in self?.confirmCredit(id, title: sender.title) }
    }

    private func confirmCredit(_ id: String, title: String) {
        guard !redeeming else { return }
        menuOpen = true; collapseTimer?.invalidate()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = "使用这张重置券？"
        alert.informativeText = "\(title)\n\n确认后会消耗 1 张券并重置符合条件的 Codex 额度。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "使用重置券")
        let response = alert.runModal(); menuOpen = false
        guard response == .alertSecondButtonReturn else { scheduleCollapse(); return }
        redeeming = true; view.needsDisplay = true
        // Re-read eligibility immediately before redemption.
        bridge.request("account/rateLimits/read") { [weak self] result in
            guard let self else { return }
            do {
                let latest = try Usage.parse(result.get()); self.usage = latest
                guard latest.eligible, latest.credits.contains(where: { $0.id == id && ($0.expires ?? .distantFuture) > Date() }) else {
                    throw WidgetError.message("额度或券状态已变化，本次未使用重置券。")
                }
                let key = self.pendingRedemption?.credit == id ? self.pendingRedemption!.key : UUID().uuidString
                self.pendingRedemption = (id, key)
                UserDefaults.standard.set(id, forKey: "pendingCredit")
                UserDefaults.standard.set(key, forKey: "pendingKey")
                self.consume(id: id, key: key)
            } catch { self.finishRedemption(error.localizedDescription) }
        }
    }

    private func consume(id: String, key: String) {
        bridge.request("account/rateLimitResetCredit/consume", params: ["idempotencyKey": key, "creditId": id]) { [weak self] result in
            guard let self else { return }
            do {
                let data = try result.get(); let outcome = data["outcome"] as? String ?? "unknown"
                let messages = ["reset": "重置成功，正在刷新额度。", "alreadyRedeemed": "这次重置已完成，正在刷新额度。", "nothingToReset": "当前没有符合条件的额度可以重置。", "noCredit": "这张重置券已不可用。"]
                if messages[outcome] != nil {
                    self.pendingRedemption = nil
                    UserDefaults.standard.removeObject(forKey: "pendingCredit")
                    UserDefaults.standard.removeObject(forKey: "pendingKey")
                }
                self.finishRedemption(messages[outcome] ?? "返回状态未知，请先刷新额度核实。")
            } catch { self.finishRedemption("请求未能确认：\(error.localizedDescription)\n请先刷新核实；重试同一张券会复用本次请求编号。") }
        }
    }

    private func finishRedemption(_ message: String) {
        redeeming = false; view.needsDisplay = true; menuOpen = true
        let alert = NSAlert(); alert.messageText = "重置券"; alert.informativeText = message; alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true); alert.runModal(); menuOpen = false
        refresh(); scheduleCollapse()
    }

    func menuWillOpen(_ menu: NSMenu) { menuOpen = true; collapseTimer?.invalidate() }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false; scheduleCollapse() }
    @objc private func quit() { NSApp.terminate(nil) }
    func stop() { refreshTimer?.invalidate(); countdownTimer?.invalidate(); hoverTimer?.invalidate(); collapseTimer?.invalidate(); save(); bridge.stop(); museBridge.stop() }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: WidgetController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        controller = WidgetController()
        if CommandLine.arguments.contains("--settings") { controller?.showSettings() }
        if CommandLine.arguments.contains("--muse-login") { controller?.museBridge.showLogin() }
    }
    func applicationWillTerminate(_ notification: Notification) { controller?.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

func selfTest() {
    let zero = Date(timeIntervalSince1970: 0)
    precondition(countdown(Date(timeIntervalSince1970: 183840), now: zero) == "2D 03:04")
    precondition(countdown(Date(timeIntervalSince1970: -60), now: zero) == "0D 00:00")

    let screens = [NSRect(x: 0, y: 30, width: 1440, height: 850), NSRect(x: -1920, y: -300, width: 1920, height: 1080)]
    for rows in 0...3 {
      Layout.rowCount = rows
      for screen in screens {
        for x in stride(from: screen.minX - 500, through: screen.maxX + 500, by: 197) {
            for y in stride(from: screen.minY - 400, through: screen.maxY + 400, by: 173) {
                let r = Layout.clamp(NSRect(x: x, y: y, width: Layout.cardWidth, height: Layout.cardHeight), to: screen)
                precondition(screen.contains(r), "Dragged widget escaped screen")
                for edge in [Edge.left, .right] {
                    for collapsed in [true, false] {
                        let dock = Layout.docked(edge: edge, collapsed: collapsed, centerY: y, screen: screen)
                        precondition(screen.contains(dock), "Docked widget escaped screen")
                    }
                }
            }
        }
    }
    }
    Layout.rowCount = 3
    for screen in screens {
        func frame(_ gap: CGFloat, _ edge: Edge) -> NSRect {
            NSRect(x: edge == .left ? screen.minX+gap : screen.maxX-Layout.cardWidth-gap, y: screen.midY-Layout.cardHeight/2, width: Layout.cardWidth, height: Layout.cardHeight)
        }
        for edge in [Edge.left, .right] {
            precondition(Layout.magneticEdge(for: frame(65, edge), in: screen, retaining: nil) == nil)
            precondition(Layout.magneticEdge(for: frame(64, edge), in: screen, retaining: nil) == edge)
            precondition(Layout.magneticEdge(for: frame(90, edge), in: screen, retaining: edge) == edge)
            precondition(Layout.magneticEdge(for: frame(105, edge), in: screen, retaining: edge) == nil)
        }
    }
    let sample: [String: Any] = ["rateLimits": ["primary": ["usedPercent": 91, "windowDurationMins": 10080, "resetsAt": 1790321526], "secondary": NSNull()], "rateLimitResetCredits": ["availableCount": 2, "credits": [["id": "sample", "status": "available", "expiresAt": 1791078990]]]]
    let usage = try! Usage.parse(sample)
    precondition(usage.remaining == 9 && usage.eligible && usage.creditCount == 2 && usage.credits.count == 1)
    precondition(usage.reset?.timeIntervalSince1970 == 1790321526)
    let twoWindows: [String: Any] = ["rateLimits": ["primary": ["usedPercent": 20, "windowDurationMins": 300, "resetsAt": 100], "secondary": ["usedPercent": 97, "windowDurationMins": 10080, "resetsAt": 200]]]
    let selected = try! Usage.parse(twoWindows)
    precondition(selected.remaining == 3 && selected.reset?.timeIntervalSince1970 == 200 && selected.creditCount == nil)
    print("PASS: magnetic entry/release hysteresis, screen bounds, both edge states, negative monitor coordinates, usage/reset pairing, missing coupon data")
}

if CommandLine.arguments.contains("--self-test") {
    selfTest()
} else if CommandLine.arguments.contains("--drag-self-test") {
    let app = NSApplication.shared; app.setActivationPolicy(.accessory)
    let c = WidgetController(preview: true)
    let screen = NSScreen.main!.frame
    func event(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: c.panel.convertPoint(fromScreen: point), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: c.panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    for side in [Edge.left, .right] {
        c.edge = nil; c.collapsed = false
        c.panel.setFrame(NSRect(x: screen.midX-Layout.cardWidth/2, y: screen.midY-Layout.cardHeight/2, width: Layout.cardWidth, height: Layout.cardHeight), display: true)
        let start = NSPoint(x: c.panel.frame.midX, y: c.panel.frame.midY)
        c.mouseDown(event(.leftMouseDown, at: start))
        for gap: CGFloat in [65, 64, 90, 105] {
            let x = side == .left ? screen.minX+gap+Layout.cardWidth/2 : screen.maxX-gap-Layout.cardWidth/2
            c.mouseDragged(event(.leftMouseDragged, at: NSPoint(x: x, y: start.y)))
            let snapped = gap == 64 || gap == 90
            precondition(c.edge == (snapped ? side : nil))
            if snapped {
                precondition(c.panel.frame.width == Layout.cardWidth+Layout.handleWidth)
                precondition(side == .left ? c.panel.frame.minX == screen.minX : c.panel.frame.maxX == screen.maxX)
                if side == .right && gap == 64 {
                    c.view.displayIfNeeded()
                    let bitmap = c.view.bitmapImageRepForCachingDisplay(in: c.view.bounds)!
                    c.view.cacheDisplay(in: c.view.bounds, to: bitmap)
                    try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "outputs/AI-Usage-magnetic-preview.png"))
                }
            }
            precondition(screen.contains(c.panel.frame))
        }
    }
    c.panel.orderOut(nil)
    print("PASS: native drag events attach both edges before mouse-up, show handle, hold within hysteresis, and detach without escaping screen")
} else if CommandLine.arguments.contains("--preview") {
    let app = NSApplication.shared; app.setActivationPolicy(.accessory)
    let c = WidgetController(preview: true)
    c.usage = Usage(remaining: 68, reset: Date().addingTimeInterval(390600), duration: 10080, creditCount: 2, credits: [], eligible: false)
    c.grokUsage = GrokUsage(remaining: 100, reset: Date().addingTimeInterval(22500))
    c.museUsage = GrokUsage(remaining: 91, reset: Date().addingTimeInterval(117600))
    c.edge = nil; c.collapsed = false
    c.panel.setFrame(NSRect(x: 0, y: 0, width: Layout.cardWidth, height: Layout.cardHeight), display: true)
    func render(_ view: NSView, _ path: String) {
        view.displayIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    }
    render(c.view, "outputs/AI-Usage-card-preview.png")
    c.collapsed = true; c.edge = .right
    c.panel.setFrame(NSRect(x: 0, y: 0, width: Layout.handleWidth, height: Layout.handleHeight), display: true)
    c.view.needsDisplay = true
    render(c.view, "outputs/AI-Usage-handle-preview.png")
    print("Rendered card and handle")
} else if CommandLine.arguments.contains("--probe") {
    let bridge = CodexBridge()
    bridge.request("account/rateLimits/read") { result in
        do {
            let usage = try Usage.parse(result.get())
            print("LIVE READ PASS remaining=\(usage.remaining) reset=\(usage.reset?.timeIntervalSince1970 ?? 0) coupons=\(usage.creditCount ?? -1) details=\(usage.credits.count)")
            bridge.stop(); exit(0)
        } catch { print("LIVE READ FAILED: \(error.localizedDescription)"); bridge.stop(); exit(1) }
    }
    dispatchMain()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate(); app.delegate = delegate; app.run()
}
