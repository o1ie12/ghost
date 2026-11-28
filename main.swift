// Ghost: a focus timer that lives in the Mac menu bar.
//
// Option + Space opens a small panel: say what you're focusing on, pick the apps (and sites) that count,
// and start. A thin line at the screen edge shows the round. Leave what counts and, after a grace period,
// the screen slowly dims (or blurs) until you come back. Pause, add five minutes, take a break early or
// end the round any time. When a round ends, a small panel asks what's next (or it flows on its own).
// Option + T opens the timer pill: drag its grip to set a length, click to start, and it stays as a
// small countdown while the round runs (or hides, in Settings).
//
// Light by design: Ghost reacts to app switches, and one slow timer (every 2 s, with tolerance) runs only
// during a session. Browser sites are read only when a focus has sites set (or site tracking is on), and
// only the domain, never full links. Stats stay on this Mac.

import Cocoa
import SwiftUI
import Carbon.HIToolbox
import ServiceManagement
import UserNotifications

// MARK: - Settings

enum Key {
    static let focusMin = "focusMin", breakMin = "breakMin", longMin = "longMin"
    static let roundsPerLong = "roundsPerLong", edge = "edge", wander = "wander"
    static let rhythm = "rhythm", autoBreak = "autoBreak", autoFocus = "autoFocus"
    static let sound = "sound", notify = "notify", barStyle = "barStyle"
    static let grace = "grace", dim = "dim", askFocus = "askFocus", appearance = "appearance"
    static let trackSites = "trackSites", recent = "recentFocus", schedulePath = "schedulePath"
    static let pillDuring = "pillDuring", pillMin = "pillMin", pillX = "pillX", pillY = "pillY"
}

let defaults = UserDefaults.standard

struct Rhythm { let id: String, name: String, focus: Int, rest: Int, long: Int, every: Int }
let rhythms = [
    Rhythm(id: "classic", name: "Classic 25 / 5", focus: 25, rest: 5, long: 15, every: 4),
    Rhythm(id: "deep", name: "Deep 50 / 10", focus: 50, rest: 10, long: 20, every: 3),
    Rhythm(id: "sprint", name: "Sprint 15 / 3", focus: 15, rest: 3, long: 10, every: 4),
]

let alertSounds = ["Glass", "Hero", "Ping", "Purr", "Pop", "Tink", "Submarine", "Funk", "Blow", "Bottle", "Frog", "Morse", "Sosumi", "Basso"]

/// The folder Today and Claude share (schedule.md, today_status.json). Ghost reads the plan from it and
/// writes ghost_status.json next to it.
var planFolder: URL {
    let path = defaults.string(forKey: Key.schedulePath) ?? "~/Downloads/claude/schedule.md"
    return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).deletingLastPathComponent()
}

/// Days roll over at 4 am, like Today, so late nights count as the same day
func ghostDay(_ date: Date = Date()) -> Date { Calendar.current.startOfDay(for: date.addingTimeInterval(-4 * 3600)) }
func dayKey(_ date: Date = Date()) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: ghostDay(date))
}

func minutesText(_ seconds: Double) -> String { "\(Int((seconds / 60).rounded())) min" }
func hoursText(_ minutes: Int) -> String {
    minutes < 60 ? "\(minutes) min" : (minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min")
}

// MARK: - Look: Claude-style paper, clay accent, serif headings

func dyn(_ light: UInt32, _ dark: UInt32) -> NSColor {
    func ns(_ h: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(h >> 16 & 255) / 255, green: CGFloat(h >> 8 & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: 1)
    }
    return NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ns(dark) : ns(light) }
}

enum Theme {
    static let bgNS = dyn(0xFAF9F5, 0x262624)
    static let bg = Color(nsColor: bgNS)
    static let card = Color(nsColor: dyn(0xFFFFFF, 0x30302E))
    static let sunk = Color(nsColor: dyn(0xF0EEE6, 0x1F1E1D))
    static let ink = Color(nsColor: dyn(0x3D3929, 0xF5F4EE))
    static let secondary = Color(nsColor: dyn(0x73726C, 0xA6A39A))
    static let tertiary = Color(nsColor: dyn(0xA3A096, 0x7A786F))
    static let hairline = Color(nsColor: dyn(0xE8E6DC, 0x3E3E38))
    static let clayNS = dyn(0xC96442, 0xD97757)
    static let clay = Color(nsColor: clayNS)
    static let claySoft = Color(nsColor: dyn(0xF5E6DE, 0x45302A))
    static let onClay = Color.white
}

extension Font {
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .serif) }
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
}

struct ClayButton: ButtonStyle {
    var prominent = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(13, .medium))
            .padding(.horizontal, 14).frame(height: 30)
            .foregroundStyle(prominent ? Theme.onClay : Theme.ink)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(prominent ? Theme.clay : Theme.sunk))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(prominent ? .clear : Theme.hairline, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct Chip: View {
    let text: String
    var onRemove: (() -> Void)?
    var body: some View {
        HStack(spacing: 6) {
            Text(text).font(.ui(12)).foregroundStyle(Theme.ink).lineLimit(1)
            if let onRemove {
                Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.tertiary)
            }
        }
        .padding(.horizontal, 10).frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.sunk))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

/// Simple wrapping row for chips
struct Flow: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += row + spacing; row = 0 }
            x += s.width + spacing; row = max(row, s.height)
        }
        return CGSize(width: width, height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; row = max(row, s.height)
        }
    }
}

// MARK: - Focus targets

/// What a round is about: a name, the apps that count, and (optionally) the sites that count in a browser
struct FocusTarget: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var apps: [String] = []        // bundle IDs
    var appNames: [String] = []    // display names, same order
    var sites: [String] = []       // domains like ixl.com
}

enum Browser {
    private static let scripts: [String: String] = [
        "com.google.Chrome": "tell application id \"com.google.Chrome\" to get URL of active tab of front window",
        "com.brave.Browser": "tell application id \"com.brave.Browser\" to get URL of active tab of front window",
        "com.microsoft.edgemac": "tell application id \"com.microsoft.edgemac\" to get URL of active tab of front window",
        "company.thebrowser.Browser": "tell application id \"company.thebrowser.Browser\" to get URL of active tab of front window",
        "com.apple.Safari": "tell application id \"com.apple.Safari\" to get URL of front document",
    ]
    static func supported(_ id: String) -> Bool { scripts[id] != nil }

    /// The domain of the front tab (no path, no www). Asks macOS for permission the first time.
    @MainActor static func domain(_ id: String) -> String? {
        guard let source = scripts[id], let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        guard let url = script.executeAndReturnError(&error).stringValue,
              let host = URL(string: url)?.host?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func clean(_ site: String) -> String {
        var s = site.trimmingCharacters(in: .whitespaces).lowercased()
        if let host = URL(string: s.contains("://") ? s : "https://" + s)?.host { s = host }
        return s.hasPrefix("www.") ? String(s.dropFirst(4)) : s
    }
}

// MARK: - Stats storage

struct Round: Codable {
    var start: Date
    var focus: Double              // seconds on what counts
    var away: Double               // seconds elsewhere
    var app: String                // first app (kept for older rounds)
    var done: Bool                 // ran to the end
    var intention: String?
    var apps: [String: Double]?    // focused seconds per app
    var sites: [String: Double]?   // focused seconds per domain
}

@MainActor final class Store: ObservableObject {
    static let shared = Store()
    @Published private(set) var rounds: [Round] = []
    @Published private(set) var presets: [FocusTarget] = []

    private let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ghost", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    init() {
        if let data = try? Data(contentsOf: dir.appendingPathComponent("rounds.json")),
           let saved = try? JSONDecoder().decode([Round].self, from: data) { rounds = saved }
        if let data = try? Data(contentsOf: dir.appendingPathComponent("presets.json")),
           let saved = try? JSONDecoder().decode([FocusTarget].self, from: data) { presets = saved }
    }

    func add(_ round: Round) {
        rounds.append(round)
        if let data = try? JSONEncoder().encode(rounds) { try? data.write(to: dir.appendingPathComponent("rounds.json"), options: .atomic) }
        writeStatus()
    }

    func savePreset(_ t: FocusTarget) {
        presets.removeAll { $0.name.lowercased() == t.name.lowercased() }
        presets.insert(t, at: 0)
        savePresets()
    }
    func deletePreset(_ id: UUID) { presets.removeAll { $0.id == id }; savePresets() }
    private func savePresets() {
        if let data = try? JSONEncoder().encode(presets) { try? data.write(to: dir.appendingPathComponent("presets.json"), options: .atomic) }
    }

    var recent: [String] { defaults.stringArray(forKey: Key.recent) ?? [] }
    func addRecent(_ name: String) {
        var r = recent.filter { $0.lowercased() != name.lowercased() }
        r.insert(name, at: 0)
        defaults.set(Array(r.prefix(6)), forKey: Key.recent)
    }

    /// Today's open items from the Today app (today_status.json), or today's line in schedule.md.
    /// Read in the background: the first read can wait on macOS's folder permission prompt.
    @Published private(set) var plan: [String] = []
    func refreshPlan() {
        let folder = planFolder, key = dayKey()
        DispatchQueue.global(qos: .userInitiated).async {
            let items = Store.readPlan(folder, key)
            DispatchQueue.main.async { MainActor.assumeIsolated { Store.shared.plan = items } }
        }
    }
    nonisolated static func readPlan(_ folder: URL, _ key: String) -> [String] {
        if let data = try? Data(contentsOf: folder.appendingPathComponent("today_status.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           json["day"] as? String == key, let open = json["open"] as? [[String: Any]] {
            return Array(open.compactMap { $0["text"] as? String }.prefix(6))
        }
        guard let text = try? String(contentsOf: folder.appendingPathComponent("schedule.md"), encoding: .utf8) else { return [] }
        for line in text.components(separatedBy: .newlines) where line.hasPrefix(key) {
            return line.split(separator: "|").dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return []
    }

    /// ghost_status.json next to the plan, so Claude can see real focus time when planning
    func writeStatus() {
        let folder = planFolder
        let today = ghostDay()
        var byFocus: [String: Int] = [:], last7: [String: Int] = [:]
        var todayMin = 0.0, todayRounds = 0
        for r in rounds {
            let d = ghostDay(r.start)
            if d == today {
                todayMin += r.focus
                if r.done { todayRounds += 1 }
                byFocus[r.intention ?? r.app, default: 0] += Int(r.focus / 60)
            }
            if let age = Calendar.current.dateComponents([.day], from: d, to: today).day, age < 7 {
                last7[dayKey(r.start), default: 0] += Int(r.focus / 60)
            }
        }
        let status: [String: Any] = ["app": "Ghost", "day": dayKey(), "focusMinutesToday": Int(todayMin / 60),
                                     "roundsToday": todayRounds, "byFocusToday": byFocus, "focusMinutesLast7Days": last7]
        guard let data = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys]) else { return }
        // Written in the background, so a permission prompt never freezes Ghost
        DispatchQueue.global(qos: .utility).async {
            guard FileManager.default.fileExists(atPath: folder.path) else { return }
            try? data.write(to: folder.appendingPathComponent("ghost_status.json"), options: .atomic)
        }
    }
}

// MARK: - Overlay windows (click-through, on every Space, over full-screen apps)

let overlayLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))

@MainActor func makeOverlay(_ frame: NSRect, level: NSWindow.Level) -> NSWindow {
    let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
    w.isOpaque = false
    w.backgroundColor = .clear
    w.hasShadow = false
    w.ignoresMouseEvents = true
    w.level = level
    w.isReleasedWhenClosed = false
    w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    return w
}

/// The thin clay line along the top (Sand) or bottom (Tide) edge of the main screen
@MainActor final class EdgeLine {
    private var window: NSWindow?
    private let bar = CALayer()
    private let thickness: CGFloat = 3

    func show(atTop: Bool) {
        guard let screen = NSScreen.main else { return }
        let f = screen.frame
        let frame = NSRect(x: f.minX, y: atTop ? f.maxY - thickness : f.minY, width: f.width, height: thickness)
        if window == nil {
            let w = makeOverlay(frame, level: overlayLevel)
            let v = NSView(frame: NSRect(origin: .zero, size: frame.size))
            v.wantsLayer = true
            bar.anchorPoint = CGPoint(x: 0, y: 0.5)
            v.layer?.addSublayer(bar)
            w.contentView = v
            window = w
        }
        window?.setFrame(frame, display: false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bar.bounds = CGRect(x: 0, y: 0, width: frame.width, height: thickness)
        bar.position = CGPoint(x: 0, y: thickness / 2)
        var color = Theme.clayNS.cgColor
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance { color = Theme.clayNS.cgColor }
        bar.backgroundColor = color
        CATransaction.commit()
        window?.orderFrontRegardless()
    }

    func set(_ value: Double) { bar.setValue(min(1, max(0, value)), forKeyPath: "transform.scale.x") }
    func hide() { window?.orderOut(nil) }
}

/// The dim or blur that slowly covers the screen while you are away from what counts
@MainActor final class Veil {
    private var windows: [NSWindow] = []

    func show(blur: Bool, strength: CGFloat) {
        for w in windows { w.orderOut(nil) }
        windows = NSScreen.screens.map { screen in
            let w = makeOverlay(screen.frame, level: NSWindow.Level(rawValue: overlayLevel.rawValue - 1))
            if blur {
                let v = NSVisualEffectView()
                v.material = .fullScreenUI
                v.blendingMode = .behindWindow
                v.state = .active
                w.contentView = v
            } else {
                let v = NSView()
                v.wantsLayer = true
                v.layer?.backgroundColor = NSColor.black.cgColor
                w.contentView = v
            }
            w.alphaValue = 0
            w.orderFrontRegardless()
            return w
        }
        let target: CGFloat = blur ? 0.97 : strength
        let ws = windows
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 30
            ctx.timingFunction = CAMediaTimingFunction(name: .linear)
            for w in ws { w.animator().alphaValue = target }
        }
    }

    func hide() {
        let ws = windows
        windows = []
        guard !ws.isEmpty else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; for w in ws { w.animator().alphaValue = 0 } },
                                             completionHandler: { for w in ws { w.orderOut(nil) } })
    }
}

/// A small note near the top of the screen that fades after a few seconds
@MainActor final class Toast {
    private var window: NSWindow?

    func show(_ text: String) {
        window?.orderOut(nil)
        guard let screen = NSScreen.main else { return }
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = NSColor(Theme.ink)
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + 36, height: 36)
        let vf = screen.visibleFrame
        let frame = NSRect(x: vf.midX - size.width / 2, y: vf.maxY - size.height - 12, width: size.width, height: size.height)
        let w = makeOverlay(frame, level: overlayLevel)
        w.hasShadow = true
        let v = NSView(frame: NSRect(origin: .zero, size: size))
        v.wantsLayer = true
        v.layer?.cornerRadius = 10
        v.layer?.borderWidth = 1
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            v.layer?.backgroundColor = Theme.bgNS.cgColor
            v.layer?.borderColor = NSColor(Theme.hairline).cgColor
        }
        label.frame.origin = NSPoint(x: 18, y: (size.height - label.frame.height) / 2)
        v.addSubview(label)
        w.contentView = v
        w.alphaValue = 0
        w.orderFrontRegardless()
        window = w
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; w.animator().alphaValue = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            MainActor.assumeIsolated {
                NSAnimationContext.runAnimationGroup({ $0.duration = 0.5; w.animator().alphaValue = 0 }, completionHandler: {
                    w.orderOut(nil)
                    MainActor.assumeIsolated { if self?.window === w { self?.window = nil } }
                })
            }
        }
    }
}

// MARK: - The focus engine

enum EndKind { case focusDone(focus: Double, away: Double, long: Bool), breakDone }

@MainActor final class Engine: ObservableObject {
    enum Phase { case idle, focus, rest, ready }   // ready: a round ended and is waiting for you

    @Published private(set) var phase = Phase.idle
    @Published private(set) var paused = false
    @Published private(set) var beat = 0            // bumps every tick so views can refresh
    private(set) var target = FocusTarget(name: "")
    private(set) var nextIsRest = true
    private(set) var nextLong = false

    var onChange: (() -> Void)?
    var onRequestStart: (() -> Void)?
    var onEnd: ((EndKind) -> Void)?
    var onHideEnd: (() -> Void)?

    private(set) var lastApp: NSRunningApplication?
    private var start = Date(), end = Date(), lastTick = Date(), pausedAt: Date?
    private var awaySince: Date?, awayTotal = 0.0, tide = 0.0, roundsInCycle = 0, tickCount = 0
    private var appTime: [String: Double] = [:], siteTime: [String: Double] = [:]
    private var site: String?
    private var ticker: Timer?, grace: Timer?
    let line = EdgeLine(), veil = Veil(), toast = Toast()
    private let myID = Bundle.main.bundleIdentifier

    var remaining: TimeInterval { max(0, end.timeIntervalSince(paused ? (pausedAt ?? Date()) : Date())) }
    var progress: Double {
        let total = end.timeIntervalSince(start)
        return total > 0 ? min(1, max(0, 1 - remaining / total)) : 0
    }
    var focusName: String { target.name.isEmpty ? (target.appNames.first ?? "your work") : target.name }

    init() {
        let ws = NSWorkspace.shared
        if let front = ws.frontmostApplication, front.bundleIdentifier != myID, front.activationPolicy == .regular { lastApp = front }
        ws.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.activated(app) }
        }
        ws.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
        }
    }

    // MARK: Controls

    /// ⌥ Space: start (asks what you're focusing on), pause or resume, or go on after a round ends
    func primary() {
        switch phase {
        case .idle: requestStart()
        case .focus, .rest: togglePause()
        case .ready: goOn()
        }
    }

    func requestStart() {
        if defaults.bool(forKey: Key.askFocus) { onRequestStart?() } else { quickStart() }
    }

    /// Starts right away on the app in front, or repeats the last focus
    func quickStart() {
        guard let app = lastApp, let id = app.bundleIdentifier else {
            toast.show("Click into the app you want to focus on, then press ⌥ Space"); return
        }
        begin(FocusTarget(name: app.localizedName ?? "Focus", apps: [id], appNames: [app.localizedName ?? id]))
    }

    func begin(_ t: FocusTarget, minutes: Double? = nil) {
        target = t
        roundsInCycle = 0
        Store.shared.addRecent(focusName)
        beginFocus(minutes: minutes)
    }

    func togglePause() { paused ? resume() : pause() }

    func pause() {
        guard phase == .focus || phase == .rest, !paused else { return }
        if let since = awaySince { awayTotal += Date().timeIntervalSince(since) }
        clearAway()
        paused = true
        pausedAt = Date()
        ticker?.invalidate(); ticker = nil
        toast.show("Paused · \(minutesText(remaining)) left")
        changed()
    }

    func resume() {
        guard paused, let at = pausedAt else { return }
        let gap = Date().timeIntervalSince(at)
        start += gap; end += gap
        lastTick = Date()
        paused = false; pausedAt = nil
        startTicker()
        if phase == .focus { evaluate() }
        changed()
    }

    /// +5 minutes to the running round, or 5 more minutes of whatever just ended
    func extend() {
        switch phase {
        case .focus, .rest:
            end += 300; updateLine(); changed()
            toast.show("+5 min · \(minutesText(remaining)) left")
        case .ready:
            if nextIsRest { beginFocus(minutes: 5) } else { beginRest(long: false, minutes: 5) }
        case .idle: break
        }
    }

    func breakNow() {
        guard phase == .focus else { return }
        let (f, _) = record(done: false)
        toast.show("Break started early · \(minutesText(f)) focused")
        beginRest(long: false)
    }

    func skipBreak() {
        guard phase == .rest || (phase == .ready && !nextIsRest) else { return }
        beginFocus()
    }

    /// Go on after a round ended: start the break, or the next focus
    func goOn() {
        guard phase == .ready else { return }
        if nextIsRest { beginRest(long: nextLong) } else { beginFocus() }
    }

    func stop() {
        guard phase != .idle else { return }
        if phase == .focus {
            let (f, a) = record(done: false)
            toast.show("Ended · \(minutesText(f)) on \(focusName) · \(minutesText(a)) away")
        } else {
            toast.show("Ended")
        }
        clearAway()
        ticker?.invalidate(); ticker = nil
        line.hide()
        onHideEnd?()
        phase = .idle; paused = false; pausedAt = nil
        roundsInCycle = 0
        changed()
    }

    // MARK: Phases

    private func seconds(_ key: String) -> Double { Double(max(1, defaults.integer(forKey: key))) * 60 }

    private func beginFocus(minutes: Double? = nil) {
        onHideEnd?()
        phase = .focus; paused = false; pausedAt = nil
        start = Date()
        end = start.addingTimeInterval(minutes.map { $0 * 60 } ?? seconds(Key.focusMin))
        lastTick = start
        awaySince = nil; awayTotal = 0; tide = 0
        appTime = [:]; siteTime = [:]
        clearAway()
        showLine()
        startTicker()
        evaluate()
        changed()
    }

    private func beginRest(long: Bool, minutes: Double? = nil) {
        onHideEnd?()
        phase = .rest; paused = false; pausedAt = nil
        start = Date()
        end = start.addingTimeInterval(minutes.map { $0 * 60 } ?? seconds(long ? Key.longMin : Key.breakMin))
        lastTick = start
        clearAway()
        showLine()
        startTicker()
        changed()
    }

    private func finishFocus() {
        let (f, a) = record(done: true)
        clearAway()
        roundsInCycle += 1
        let long = roundsInCycle % max(1, defaults.integer(forKey: Key.roundsPerLong)) == 0
        alert(title: "Focus done", body: "\(minutesText(f)) on \(focusName). \(long ? "Long break" : "Break") when you're ready")
        if defaults.bool(forKey: Key.autoBreak) {
            toast.show("\(minutesText(f)) focused · \(long ? "Long break" : "Break") \(defaults.integer(forKey: long ? Key.longMin : Key.breakMin)) min")
            beginRest(long: long)
        } else {
            ticker?.invalidate(); ticker = nil
            phase = .ready; nextIsRest = true; nextLong = long
            line.set(1)
            onEnd?(.focusDone(focus: f, away: a, long: long))
            changed()
        }
    }

    private func finishRest() {
        alert(title: "Break's over", body: "Next: \(focusName)")
        if defaults.bool(forKey: Key.autoFocus) {
            toast.show("Back to \(focusName)")
            beginFocus()
        } else {
            ticker?.invalidate(); ticker = nil
            phase = .ready; nextIsRest = false
            line.hide()
            onEnd?(.breakDone)
            changed()
        }
    }

    private func alert(title: String, body: String) {
        let sound = defaults.string(forKey: Key.sound) ?? "Glass"
        if sound != "None" { NSSound(named: sound)?.play() }
        guard defaults.bool(forKey: Key.notify) else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Saves the round (if it lasted at least a minute) and returns (focused, away) seconds
    private func record(done: Bool) -> (Double, Double) {
        let now = min(paused ? (pausedAt ?? Date()) : Date(), end)
        let away = awayTotal + (awaySince.map { max(0, now.timeIntervalSince($0)) } ?? 0)
        let focus = max(0, now.timeIntervalSince(start) - away)
        if focus + away >= 60 {
            Store.shared.add(Round(start: start, focus: focus, away: away, app: target.appNames.first ?? focusName, done: done,
                                   intention: focusName, apps: appTime, sites: siteTime.isEmpty ? nil : siteTime))
        }
        return (focus, away)
    }

    // MARK: Away and back

    private func activated(_ app: NSRunningApplication) {
        if app.bundleIdentifier == myID { return }   // Ghost's own windows don't count either way
        if app.activationPolicy != .regular { return } // nor system prompts and background agents
        lastApp = app
        if phase == .focus && !paused { evaluate() }
    }

    /// Decides whether what's in front counts: an allowed app, and in a browser an allowed site (if any are set)
    private func evaluate() {
        guard phase == .focus, !paused, let front = NSWorkspace.shared.frontmostApplication,
              let id = front.bundleIdentifier, id != myID, front.activationPolicy == .regular else { return }
        var counts = target.apps.isEmpty || target.apps.contains(id)
        site = nil
        if Browser.supported(id), !target.sites.isEmpty || defaults.bool(forKey: Key.trackSites) {
            site = Browser.domain(id)
            if counts, !target.sites.isEmpty, let s = site {
                counts = target.sites.contains { s == $0 || s.hasSuffix("." + $0) }
            }
        }
        counts ? comeBack() : leave()
    }

    private func leave() {
        guard awaySince == nil else { return }
        awaySince = Date()
        let wait = Double(max(3, defaults.integer(forKey: Key.grace)))
        grace = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                let strength = ["light": 0.35, "strong": 0.85][defaults.string(forKey: Key.dim) ?? ""] ?? 0.6
                self?.veil.show(blur: defaults.string(forKey: Key.wander) == "blur", strength: strength)
            }
        }
    }

    private func comeBack() {
        guard let since = awaySince else { return }
        awayTotal += Date().timeIntervalSince(since)
        clearAway()
    }

    private func clearAway() {
        grace?.invalidate(); grace = nil
        awaySince = nil
        veil.hide()
    }

    // MARK: Ticker and edge line

    private func startTicker() {
        ticker?.invalidate()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func tick() {
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now
        if phase == .focus {
            // Tide grows while you stay, and washes back three times as fast while you're away
            tide += (awaySince == nil ? dt : -3 * dt) / end.timeIntervalSince(start)
            tide = min(1, max(0, tide))
            if awaySince == nil, let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier != myID {
                appTime[front.localizedName ?? "App", default: 0] += dt
                if let s = site { siteTime[s, default: 0] += dt }
            }
            // A browser can change tabs without an app switch, so look again every few seconds
            tickCount += 1
            if tickCount % 2 == 0, let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, Browser.supported(id) { evaluate() }
        }
        if now >= end {
            if phase == .focus { finishFocus() } else { finishRest() }
            return
        }
        updateLine()
        changed()
    }

    private var edge: String { defaults.string(forKey: Key.edge) ?? "sand" }

    private func showLine() {
        if edge == "none" { line.hide(); return }
        line.show(atTop: edge == "sand")
        updateLine()
    }

    private func updateLine() {
        let left = remaining / max(1, end.timeIntervalSince(start))
        switch phase {
        case .focus: line.set(edge == "tide" ? tide : left)
        case .rest: line.set(1 - left)   // the line refills during a break
        default: break
        }
    }

    private func changed() { beat &+= 1; onChange?() }
}

// MARK: - Floating panels (start and end of a round)

final class FloatingPanel: NSPanel {
    var keyable = true
    override var canBecomeKey: Bool { keyable }
}

final class FirstClickHost<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor func makePanel<V: View>(_ view: V, keyable: Bool) -> FloatingPanel {
    let p = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                          styleMask: keyable ? [.borderless] : [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    p.keyable = keyable
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = true
    p.level = .floating
    p.isReleasedWhenClosed = false
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    if keyable {
        // Follows the content's size as it changes (plan items load in the background)
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        p.contentViewController = host
        p.setContentSize(host.view.fittingSize)
    } else {
        let host = FirstClickHost(rootView: view)   // buttons work on the first click without focusing the panel
        p.contentView = host
        p.setContentSize(host.fittingSize)
    }
    pinTop(p)
    // Keep it hanging from the top of the screen when its height changes
    NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: p, queue: .main) { _ in
        MainActor.assumeIsolated { pinTop(p) }
    }
    return p
}

@MainActor func pinTop(_ p: NSWindow) {
    guard let vf = NSScreen.main?.visibleFrame else { return }
    let s = p.frame.size
    let origin = NSPoint(x: vf.midX - s.width / 2, y: vf.maxY - s.height - 12)
    if p.frame.origin != origin { p.setFrameOrigin(origin) }
}

struct PanelChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.bg))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// "What are you focusing on?" with suggestions from Today, presets and recent focuses
struct StartView: View {
    let frontApp: NSRunningApplication?
    let onStart: (FocusTarget, Bool) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @State private var apps: [(id: String, name: String)] = []
    @State private var sites: [String] = []
    @State private var siteDraft = ""
    @State private var save = false
    @AppStorage(Key.focusMin) private var focusMin = 25
    @ObservedObject private var store = Store.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What are you focusing on?").font(.serif(20, .medium)).foregroundStyle(Theme.ink)
            TextField("", text: $name, prompt: Text("IXL K3 to K6").foregroundColor(Theme.tertiary))
                .textFieldStyle(.plain).font(.ui(15)).foregroundStyle(Theme.ink)
                .padding(.horizontal, 12).frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
                .onSubmit(start)

            let plan = store.plan
            if !plan.isEmpty { suggestions("From Today", plan) { name = $0 } }
            if !store.presets.isEmpty {
                suggestions("Presets", store.presets.map(\.name)) { n in
                    if let p = store.presets.first(where: { $0.name == n }) { use(p) }
                }
            }
            let recent = store.recent.filter { r in !plan.contains(r) && !store.presets.contains { $0.name == r } }
            if !recent.isEmpty { suggestions("Recent", recent) { name = $0 } }

            VStack(alignment: .leading, spacing: 8) {
                label("Counts as focus")
                Flow {
                    ForEach(apps, id: \.id) { a in Chip(text: a.name) { apps.removeAll { $0.id == a.id } } }
                    Menu {
                        ForEach(runningApps(), id: \.bundleIdentifier) { app in
                            Button(app.localizedName ?? "App") {
                                if let id = app.bundleIdentifier, !apps.contains(where: { $0.id == id }) {
                                    apps.append((id, app.localizedName ?? id))
                                }
                            }
                        }
                    } label: { Text("Add app").font(.ui(12, .medium)) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .foregroundStyle(Theme.clay)
                        .padding(.horizontal, 6).frame(height: 26)
                }
                if apps.isEmpty { Text("Any app counts").font(.ui(11)).foregroundStyle(Theme.tertiary) }
            }

            if apps.contains(where: { Browser.supported($0.id) }) {
                VStack(alignment: .leading, spacing: 8) {
                    label("Sites that count in the browser")
                    Flow {
                        ForEach(sites, id: \.self) { s in Chip(text: s) { sites.removeAll { $0 == s } } }
                        TextField("", text: $siteDraft, prompt: Text("Add a site, like ixl.com").foregroundColor(Theme.tertiary))
                            .textFieldStyle(.plain).font(.ui(12)).frame(width: 170, height: 26)
                            .onSubmit {
                                let s = Browser.clean(siteDraft)
                                if !s.isEmpty, !sites.contains(s) { sites.append(s) }
                                siteDraft = ""
                            }
                    }
                    Text(sites.isEmpty ? "No sites set: any page counts" : "Only the domain is checked, never the full link")
                        .font(.ui(11)).foregroundStyle(Theme.tertiary)
                }
            }

            Rectangle().fill(Theme.hairline).frame(height: 1)
            HStack(spacing: 8) {
                Toggle("Save as preset", isOn: $save).toggleStyle(.checkbox).font(.ui(12)).foregroundStyle(Theme.secondary)
                Spacer()
                Button("Cancel", action: onCancel).buttonStyle(ClayButton(prominent: false)).keyboardShortcut(.cancelAction)
                Button("Start · \(focusMin) min", action: start).buttonStyle(ClayButton())
            }
        }
        .padding(22)
        .frame(width: 460)
        .modifier(PanelChrome())
        .onAppear {
            if let app = frontApp, let id = app.bundleIdentifier { apps = [(id, app.localizedName ?? id)] }
        }
        .onExitCommand(perform: onCancel)
    }

    func label(_ t: String) -> some View { Text(t).font(.ui(12, .medium)).foregroundStyle(Theme.secondary) }

    func suggestions(_ title: String, _ items: [String], _ pick: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            label(title)
            Flow {
                ForEach(items, id: \.self) { item in
                    Button { pick(item) } label: { Chip(text: item) }.buttonStyle(.plain)
                }
            }
        }
    }

    func use(_ p: FocusTarget) {
        name = p.name
        apps = Array(zip(p.apps, p.appNames)).map { (id: $0.0, name: $0.1) }
        sites = p.sites
    }

    func runningApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    func start() {
        let title = name.trimmingCharacters(in: .whitespaces)
        let t = FocusTarget(name: title.isEmpty ? (apps.first?.name ?? "Focus") : title,
                            apps: apps.map(\.id), appNames: apps.map(\.name), sites: sites)
        onStart(t, save)
    }
}

/// The panel that drops in when a round ends (unless rounds flow on their own)
struct EndView: View {
    let kind: EndKind
    let engine: Engine

    var body: some View {
        HStack(spacing: 14) {
            Circle().fill(Theme.clay).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.serif(16, .medium)).foregroundStyle(Theme.ink)
                Text(subtitle).font(.ui(12)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            Spacer(minLength: 16)
            Button("End") { engine.stop() }.buttonStyle(.plain).font(.ui(12, .medium)).foregroundStyle(Theme.secondary)
            Button("+5 min") { engine.extend() }.buttonStyle(ClayButton(prominent: false))
            Button(primary) { engine.goOn() }.buttonStyle(ClayButton())
        }
        .padding(.horizontal, 18).frame(width: 500, height: 64)
        .modifier(PanelChrome())
    }

    var title: String {
        if case .focusDone = kind { return "Focus done" }
        return "Break's over"
    }
    var subtitle: String {
        switch kind {
        case .focusDone(let f, let a, _): return "\(minutesText(f)) on \(engine.focusName)" + (a >= 60 ? " · \(minutesText(a)) away" : "")
        case .breakDone: return "Next: \(engine.focusName)"
        }
    }
    var primary: String {
        switch kind {
        case .focusDone(_, _, let long): return long ? "Start long break" : "Start break"
        case .breakDone: return "Start focus"
        }
    }
}

// MARK: - Quick timer pill (drag the grip to set a length, then a small countdown while the round runs)

let pillStretch: CGFloat = 2     // points of width per minute, so the bar follows your drag

struct PillRing: View {
    let progress: Double
    var color: Color = Theme.clay
    var body: some View {
        ZStack {
            Circle().stroke(Theme.hairline, lineWidth: 2.5)
            Circle().trim(from: 0, to: max(0.02, min(1, progress)))
                .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 18, height: 18)
    }
}

struct PillView: View {
    @ObservedObject var engine: Engine
    let onStart: (Int) -> Void
    let onClose: () -> Void
    let onMore: () -> Void
    let onMove: (_ ended: Bool) -> Void
    let onSize: (CGSize) -> Void
    @AppStorage(Key.pillMin) private var minutes = 25
    @State private var dragFrom: Int?
    @State private var moved = false

    private var idle: Bool { engine.phase == .idle }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: side) {
                Image(systemName: sideIcon).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Theme.bg))
                    .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(idle ? "Close" : (engine.paused ? "Resume" : "Pause"))

            bar
                .frame(height: 40)
                .background(Capsule().fill(Theme.bg))
                .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
                .contentShape(Capsule())
                .gesture(clickOrMove)
                .contextMenu { menu }
        }
        .fixedSize()
        .background(GeometryReader { g in
            Color.clear.onAppear { onSize(g.size) }.onChange(of: g.size) { _, s in onSize(s) }
        })
    }

    private var sideIcon: String {
        if idle { return "xmark" }
        if engine.phase == .ready { return "arrow.right" }
        return engine.paused ? "play.fill" : "pause.fill"
    }

    private func side() {
        switch engine.phase {
        case .idle: onClose()
        case .ready: engine.goOn()
        case .focus, .rest: engine.togglePause()
        }
    }

    @ViewBuilder private var bar: some View {
        switch engine.phase {
        case .idle:
            HStack(spacing: 10) {
                PillRing(progress: Double(minutes) / 120)
                Text("\(minutes) min").font(.serif(15)).monospacedDigit().foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
                grip
            }
            .padding(.leading, 14)
            .frame(width: 150 + CGFloat(minutes) * pillStretch)
        case .focus, .rest:
            HStack(spacing: 10) {
                PillRing(progress: engine.progress, color: engine.phase == .rest ? Theme.tertiary : Theme.clay)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(clock(engine.remaining)).font(.serif(15)).monospacedDigit().foregroundStyle(Theme.ink)
                }
                Text(engine.phase == .rest ? "Break" : engine.focusName)
                    .font(.ui(12)).foregroundStyle(Theme.secondary).lineLimit(1).frame(maxWidth: 110, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .opacity(engine.paused ? 0.55 : 1)
        case .ready:
            HStack(spacing: 10) {
                PillRing(progress: 1)
                Text(engine.nextIsRest ? "Focus done" : "Break's over").font(.serif(15)).foregroundStyle(Theme.ink)
            }
            .padding(.horizontal, 14)
        }
    }

    /// Three bars on the right: drag them to stretch the timer
    private var grip: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { _ in Capsule().fill(Theme.tertiary).frame(width: 2.5, height: 14) }
        }
        .frame(width: 40, height: 40)
        .contentShape(Rectangle())
        .onHover { $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
        .highPriorityGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { g in
                    let from = dragFrom ?? minutes
                    dragFrom = from
                    let raw = Double(from) + Double(g.translation.width / pillStretch)
                    let m = min(120, max(5, Int((raw / 5).rounded()) * 5))
                    if m != minutes {
                        minutes = m
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    }
                }
                .onEnded { _ in dragFrom = nil }
        )
        .help("Drag to set the length")
    }

    /// A click starts (or pauses); a drag moves the pill
    private var clickOrMove: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                if !moved && hypot(g.translation.width, g.translation.height) > 3 { moved = true }
                if moved { onMove(false) }
            }
            .onEnded { _ in
                if moved { onMove(true) } else { click() }
                moved = false
            }
    }

    private func click() {
        switch engine.phase {
        case .idle: onStart(minutes)
        case .ready: engine.goOn()
        case .focus, .rest: engine.togglePause()
        }
    }

    @ViewBuilder private var menu: some View {
        switch engine.phase {
        case .idle:
            Button("Start \(minutes) min") { onStart(minutes) }
            Button("Focus with apps and sites…") { onMore() }
            Divider()
            Button("Close") { onClose() }
        case .focus, .rest:
            Button(engine.paused ? "Resume" : "Pause") { engine.togglePause() }
            Button("Add 5 minutes") { engine.extend() }
            if engine.phase == .focus { Button("Take a break now") { engine.breakNow() } }
            Button(engine.phase == .focus ? "End round" : "End") { engine.stop() }
            Divider()
            Button("Hide pill") { onClose() }
        case .ready:
            Button(engine.nextIsRest ? "Start break" : "Start focus") { engine.goOn() }
            Button("5 more minutes") { engine.extend() }
            Button("End") { engine.stop() }
        }
    }

    private func clock(_ r: TimeInterval) -> String {
        let s = Int(ceil(r))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}

// MARK: - Stats for the window

struct Stats {
    struct Day: Identifiable { let id: Int; let label: String; let minutes: Double }
    struct Row: Identifiable { var id: String { name }; let name: String; let minutes: Int }

    var todayMin = 0, todayRounds = 0, todayAway = 0, todayScore = 0
    var streak = 0, weekMin = 0
    var week: [Day] = []
    var byFocus: [Row] = [], apps: [Row] = [], sites: [Row] = []
    var heat: [Double] = []          // minutes per day, last 84 days, oldest first
    var weekMax: Double { week.map(\.minutes).max() ?? 0 }

    init(_ rounds: [Round]) {
        let cal = Calendar.current
        let today = ghostDay()
        var byDay: [Date: Double] = [:]
        var doneDays = Set<Date>()
        for r in rounds {
            let d = ghostDay(r.start)
            byDay[d, default: 0] += r.focus
            if r.done { doneDays.insert(d) }
        }

        let todays = rounds.filter { ghostDay($0.start) == today }
        let tf = todays.reduce(0) { $0 + $1.focus }, ta = todays.reduce(0) { $0 + $1.away }
        todayMin = Int(tf / 60)
        todayAway = Int((ta / 60).rounded())
        todayRounds = todays.filter(\.done).count
        todayScore = tf + ta > 0 ? Int((100 * tf / (tf + ta)).rounded()) : 0

        let letter = DateFormatter()
        letter.dateFormat = "EEEEE"
        for i in (0..<7).reversed() {
            let d = cal.date(byAdding: .day, value: -i, to: today)!
            week.append(Day(id: i, label: letter.string(from: d), minutes: (byDay[d] ?? 0) / 60))
        }
        for i in (0..<84).reversed() {
            heat.append((byDay[cal.date(byAdding: .day, value: -i, to: today)!] ?? 0) / 60)
        }

        var day = doneDays.contains(today) ? today : cal.date(byAdding: .day, value: -1, to: today)!
        while doneDays.contains(day) { streak += 1; day = cal.date(byAdding: .day, value: -1, to: day)! }

        let weekStart = cal.date(byAdding: .day, value: -6, to: today)!
        let recent = rounds.filter { ghostDay($0.start) >= weekStart }
        weekMin = Int(recent.reduce(0) { $0 + $1.focus } / 60)
        var f: [String: Double] = [:], a: [String: Double] = [:], s: [String: Double] = [:]
        for r in recent {
            f[r.intention ?? r.app, default: 0] += r.focus
            if let per = r.apps, !per.isEmpty { for (k, v) in per { a[k, default: 0] += v } } else { a[r.app, default: 0] += r.focus }
            for (k, v) in r.sites ?? [:] { s[k, default: 0] += v }
        }
        func top(_ d: [String: Double], _ n: Int) -> [Row] {
            d.sorted { $0.value > $1.value }.prefix(n).map { Row(name: $0.key, minutes: Int($0.value / 60)) }.filter { $0.minutes > 0 }
        }
        byFocus = top(f, 6); apps = top(a, 5); sites = top(s, 5)
    }
}

// MARK: - Window UI

struct GhostView: View {
    @ObservedObject var store: Store
    @ObservedObject var engine: Engine
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 22) {
                tabButton("Overview", 0); tabButton("Presets", 1); tabButton("Settings", 2)
                Spacer()
            }
            .padding(.horizontal, 32).padding(.top, 20)
            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.top, 10)
            ScrollView(showsIndicators: false) {
                Group {
                    switch tab {
                    case 0: OverviewView(store: store, engine: engine)
                    case 1: PresetsView(store: store, engine: engine)
                    default: SettingsView()
                    }
                }
                .padding(.horizontal, 32).padding(.vertical, 24)
            }
        }
        .frame(width: 560, height: 700)
        .background(Theme.bg)
    }

    func tabButton(_ title: String, _ i: Int) -> some View {
        Button { tab = i } label: {
            VStack(spacing: 8) {
                Text(title).font(.ui(13, tab == i ? .semibold : .regular)).foregroundStyle(tab == i ? Theme.ink : Theme.secondary)
                Rectangle().fill(tab == i ? Theme.clay : .clear).frame(height: 2)
            }
            .fixedSize()
        }
        .buttonStyle(.plain)
        .offset(y: 11)
    }
}

struct OverviewView: View {
    @ObservedObject var store: Store
    @ObservedObject var engine: Engine

    var body: some View {
        let s = Stats(store.rounds)
        VStack(alignment: .leading, spacing: 28) {
            if engine.phase != .idle { live }

            VStack(alignment: .leading, spacing: 4) {
                Text("Today").font(.serif(15)).foregroundStyle(Theme.secondary)
                Text(hoursText(s.todayMin)).font(.serif(44, .medium)).foregroundStyle(Theme.ink).monospacedDigit()
                Text("\(s.todayRounds) \(s.todayRounds == 1 ? "round" : "rounds") · \(s.todayAway) min away · \(s.todayScore)% focused")
                    .font(.ui(13)).foregroundStyle(Theme.secondary)
            }

            section("Last 7 days", trailing: String(format: "%.1f h", Double(s.weekMin) / 60)) {
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(s.week) { d in
                        VStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(d.id == 0 ? Theme.clay : Theme.ink.opacity(0.14))
                                .frame(width: 26, height: max(3, 84 * d.minutes / max(1, s.weekMax)))
                                .help("\(Int(d.minutes)) min")
                            Text(d.label).font(.ui(11)).foregroundStyle(Theme.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 104, alignment: .bottom)
            }

            section("Last 12 weeks", trailing: "\(s.streak)-day streak") {
                let maxHeat = max(1, s.heat.max() ?? 1)
                LazyHGrid(rows: Array(repeating: GridItem(.fixed(12), spacing: 4), count: 7), spacing: 4) {
                    ForEach(Array(s.heat.enumerated()), id: \.offset) { _, m in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(m > 0 ? Theme.clay.opacity(0.25 + 0.75 * m / maxHeat) : Theme.sunk)
                            .frame(width: 12, height: 12)
                            .help("\(Int(m)) min")
                    }
                }
                .frame(height: 108, alignment: .leading)
            }

            if !s.byFocus.isEmpty {
                section("By focus, 7 days") { bars(s.byFocus) }
            }
            HStack(alignment: .top, spacing: 28) {
                if !s.apps.isEmpty { section("Apps") { list(s.apps) } }
                if !s.sites.isEmpty { section("Sites") { list(s.sites) } }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // The round in progress, with its controls
    var live: some View {
        let title: String = {
            switch engine.phase {
            case .focus: return engine.paused ? "Paused · \(engine.focusName)" : "Focusing on \(engine.focusName)"
            case .rest: return engine.paused ? "Break paused" : "On a break"
            case .ready: return engine.nextIsRest ? "Focus done" : "Break's over"
            case .idle: return ""
            }
        }()
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.serif(18, .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                Spacer()
                if engine.phase != .ready {
                    Text("\(Int(ceil(engine.remaining / 60))) min left").font(.ui(13)).monospacedDigit().foregroundStyle(Theme.secondary)
                }
            }
            if engine.phase != .ready {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.sunk)
                        Capsule().fill(Theme.clay).frame(width: g.size.width * engine.progress)
                    }
                }
                .frame(height: 4)
            }
            HStack(spacing: 8) {
                switch engine.phase {
                case .ready:
                    Button(engine.nextIsRest ? "Start break" : "Start focus") { engine.goOn() }.buttonStyle(ClayButton())
                    Button("+5 min") { engine.extend() }.buttonStyle(ClayButton(prominent: false))
                default:
                    Button(engine.paused ? "Resume" : "Pause") { engine.togglePause() }.buttonStyle(ClayButton())
                    Button("+5 min") { engine.extend() }.buttonStyle(ClayButton(prominent: false))
                    if engine.phase == .focus { Button("Break now") { engine.breakNow() }.buttonStyle(ClayButton(prominent: false)) }
                    if engine.phase == .rest { Button("Skip break") { engine.skipBreak() }.buttonStyle(ClayButton(prominent: false)) }
                }
                Spacer()
                Button("End") { engine.stop() }.buttonStyle(.plain).font(.ui(12, .medium)).foregroundStyle(Theme.secondary)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }

    func section<V: View>(_ title: String, trailing: String? = nil, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.serif(15, .medium)).foregroundStyle(Theme.ink)
                Spacer()
                if let trailing { Text(trailing).font(.ui(12)).monospacedDigit().foregroundStyle(Theme.secondary) }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func bars(_ rows: [Stats.Row]) -> some View {
        let top = Double(max(1, rows.first?.minutes ?? 1))
        return VStack(spacing: 10) {
            ForEach(rows) { r in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(r.name).font(.ui(13)).foregroundStyle(Theme.ink).lineLimit(1)
                        Spacer()
                        Text(hoursText(r.minutes)).font(.ui(12)).monospacedDigit().foregroundStyle(Theme.secondary)
                    }
                    GeometryReader { g in
                        Capsule().fill(Theme.clay.opacity(0.8)).frame(width: max(4, g.size.width * Double(r.minutes) / top))
                    }
                    .frame(height: 3)
                }
            }
        }
    }

    func list(_ rows: [Stats.Row]) -> some View {
        VStack(spacing: 8) {
            ForEach(rows) { r in
                HStack {
                    Text(r.name).font(.ui(13)).foregroundStyle(Theme.ink).lineLimit(1)
                    Spacer()
                    Text(hoursText(r.minutes)).font(.ui(12)).monospacedDigit().foregroundStyle(Theme.secondary)
                }
            }
        }
    }
}

struct PresetsView: View {
    @ObservedObject var store: Store
    @ObservedObject var engine: Engine

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Presets").font(.serif(24, .medium)).foregroundStyle(Theme.ink)
            Text("One-click setups: a name, the apps that count, and sites for the browser. Save one by ticking Save as preset when you start a round.")
                .font(.ui(13)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            if store.presets.isEmpty {
                Text("No presets yet").font(.ui(13)).foregroundStyle(Theme.tertiary).padding(.top, 8)
            }
            ForEach(store.presets) { p in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(p.name).font(.serif(16, .medium)).foregroundStyle(Theme.ink)
                        Text(p.appNames.isEmpty ? "Any app" : p.appNames.joined(separator: ", "))
                            .font(.ui(12)).foregroundStyle(Theme.secondary)
                        if !p.sites.isEmpty {
                            Text(p.sites.joined(separator: ", ")).font(.ui(12)).foregroundStyle(Theme.tertiary)
                        }
                    }
                    Spacer()
                    Button("Start") { engine.begin(p) }.buttonStyle(ClayButton()).disabled(engine.phase != .idle)
                    Button { store.deletePreset(p.id) } label: { Image(systemName: "trash").font(.system(size: 12)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.tertiary).frame(height: 30).help("Delete preset")
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsView: View {
    @AppStorage(Key.rhythm) private var rhythm = "classic"
    @AppStorage(Key.focusMin) private var focusMin = 25
    @AppStorage(Key.breakMin) private var breakMin = 5
    @AppStorage(Key.longMin) private var longMin = 15
    @AppStorage(Key.roundsPerLong) private var roundsPerLong = 4
    @AppStorage(Key.askFocus) private var askFocus = true
    @AppStorage(Key.autoBreak) private var autoBreak = false
    @AppStorage(Key.autoFocus) private var autoFocus = false
    @AppStorage(Key.wander) private var wander = "dim"
    @AppStorage(Key.dim) private var dim = "medium"
    @AppStorage(Key.grace) private var grace = 10
    @AppStorage(Key.trackSites) private var trackSites = false
    @AppStorage(Key.sound) private var sound = "Glass"
    @AppStorage(Key.notify) private var notify = false
    @AppStorage(Key.barStyle) private var barStyle = "ring"
    @AppStorage(Key.edge) private var edge = "sand"
    @AppStorage(Key.appearance) private var appearance = "light"
    @AppStorage(Key.pillDuring) private var pillDuring = "show"
    @State private var atLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            group("Rhythm") {
                row("Preset") {
                    Picker("", selection: $rhythm) {
                        ForEach(rhythms, id: \.id) { Text($0.name).tag($0.id) }
                        Text("Custom").tag("custom")
                    }.labelsHidden().fixedSize()
                }
                divider
                stepper("Focus", $focusMin, 5...120, 5, "min")
                divider
                stepper("Break", $breakMin, 1...30, 1, "min")
                divider
                stepper("Long break", $longMin, 5...60, 5, "min")
                divider
                stepper("Long break every", $roundsPerLong, 2...8, 1, "rounds")
            }
            group("Flow") {
                toggle("Ask what you're focusing on", $askFocus)
                divider
                toggle("Start breaks automatically", $autoBreak)
                divider
                toggle("Start the next focus automatically", $autoFocus)
            }
            group("When you wander") {
                row("Screen") {
                    Picker("", selection: $wander) { Text("Dim").tag("dim"); Text("Blur").tag("blur") }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 140)
                }
                divider
                row("Dim strength") {
                    Picker("", selection: $dim) { Text("Light").tag("light"); Text("Medium").tag("medium"); Text("Strong").tag("strong") }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 210)
                }
                divider
                stepper("Grace period", $grace, 5...60, 5, "sec")
                divider
                toggle("Track sites in every round", $trackSites)
            }
            group("Alerts") {
                row("Sound") {
                    Picker("", selection: $sound) {
                        Text("None").tag("None")
                        ForEach(alertSounds, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden().fixedSize()
                }
                divider
                toggle("Notification when a round ends", $notify)
            }
            group("Look") {
                row("Menu bar") {
                    Picker("", selection: $barStyle) { Text("Ring and time").tag("ring"); Text("Time").tag("time"); Text("Ring").tag("icon") }
                        .labelsHidden().fixedSize()
                }
                divider
                row("Edge line") {
                    Picker("", selection: $edge) { Text("Sand").tag("sand"); Text("Tide").tag("tide"); Text("None").tag("none") }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                }
                divider
                row("Timer pill during rounds") {
                    Picker("", selection: $pillDuring) { Text("Show").tag("show"); Text("Hide").tag("hide") }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 140)
                }
                divider
                row("Appearance") {
                    Picker("", selection: $appearance) { Text("Light").tag("light"); Text("Dark").tag("dark"); Text("System").tag("system") }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                }
                divider
                toggle("Open at login", $atLogin)
            }
            group("Shortcuts") {
                row("Start, pause or resume") { keys("⌥", "Space") }
                divider
                row("End the round") { keys("⌥", "⇧", "Space") }
                divider
                row("Quick timer (drag to set)") { keys("⌥", "T") }
            }
            Text("Plan suggestions come from Today (\(planFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))). Ghost writes ghost_status.json there so Claude can see your focus time.")
                .font(.ui(11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .tint(Theme.clay)
        .onChange(of: rhythm) { _, id in
            guard let r = rhythms.first(where: { $0.id == id }) else { return }
            focusMin = r.focus; breakMin = r.rest; longMin = r.long; roundsPerLong = r.every
        }
        .onChange(of: focusMin) { _, _ in matchRhythm() }
        .onChange(of: breakMin) { _, _ in matchRhythm() }
        .onChange(of: sound) { _, s in if s != "None" { NSSound(named: s)?.play() } }
        .onChange(of: notify) { _, on in
            if on { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
        }
        .onChange(of: appearance) { _, v in NSApp.appearance = appearanceFor(v) }
        .onChange(of: atLogin) { _, on in
            do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
            catch { atLogin = SMAppService.mainApp.status == .enabled }
        }
    }

    func matchRhythm() {
        rhythm = rhythms.first { $0.focus == focusMin && $0.rest == breakMin && $0.long == longMin && $0.every == roundsPerLong }?.id ?? "custom"
    }

    func group<V: View>(_ title: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.serif(15, .medium)).foregroundStyle(Theme.ink)
            VStack(spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        }
    }

    var divider: some View { Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 16) }

    func row<V: View>(_ label: String, @ViewBuilder _ content: () -> V) -> some View {
        HStack {
            Text(label).font(.ui(13)).foregroundStyle(Theme.ink)
            Spacer()
            content()
        }
        .padding(.horizontal, 16).frame(minHeight: 44)
    }

    func toggle(_ label: String, _ value: Binding<Bool>) -> some View {
        row(label) { Toggle("", isOn: value).toggleStyle(.switch).controlSize(.small).labelsHidden() }
    }

    func stepper(_ label: String, _ value: Binding<Int>, _ range: ClosedRange<Int>, _ step: Int, _ unit: String) -> some View {
        row(label) {
            Text("\(value.wrappedValue) \(unit)").font(.ui(13)).monospacedDigit().foregroundStyle(Theme.secondary)
            Stepper("", value: value, in: range, step: step).labelsHidden()
        }
    }

    func keys(_ k: String...) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(k.enumerated()), id: \.offset) { _, key in
                Text(key).font(.ui(11, .medium)).foregroundStyle(Theme.ink)
                    .padding(.horizontal, 7).frame(minWidth: 22, minHeight: 22)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.sunk))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.hairline, lineWidth: 1))
            }
        }
    }
}

@MainActor func appearanceFor(_ value: String) -> NSAppearance? {
    switch value {
    case "dark": return NSAppearance(named: .darkAqua)
    case "system": return nil
    default: return NSAppearance(named: .aqua)
    }
}

// MARK: - App: menu bar item, menu, window, panels, hot keys

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let engine = Engine()
    private var item: NSStatusItem!
    private var window: NSWindow?
    private var startPanel: FloatingPanel?, endPanel: FloatingPanel?
    private var hotKeys: [EventHotKeyRef?] = [nil, nil, nil]
    private var pill: FloatingPanel?
    private var lastPhase = Engine.Phase.idle
    private var moveStart: (mouse: NSPoint, origin: NSPoint)?
    private var hotKeyTaken = false
    private var styleObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.appearance = appearanceFor(defaults.string(forKey: Key.appearance) ?? "light")
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        item.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        item.button?.imagePosition = .imageLeading
        engine.onChange = { [weak self] in self?.refreshItem(); self?.phaseChanged() }
        engine.onRequestStart = { [weak self] in self?.showStart() }
        engine.onEnd = { [weak self] kind in self?.showEnd(kind) }
        engine.onHideEnd = { [weak self] in self?.endPanel?.orderOut(nil); self?.endPanel = nil }
        styleObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshItem() }
        }
        refreshItem()
        registerHotKeys()
        watchPillKeys()
        Store.shared.refreshPlan()
        if CommandLine.arguments.contains("--window") { openWindow() }
        if CommandLine.arguments.contains("--start") { showStart() }
        if CommandLine.arguments.contains("--pill") { showPill() }
    }

    // Opening Ghost again (from Applications or Spotlight) shows its window
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openWindow(); return false
    }

    // MARK: Menu bar

    private func symbol(_ name: String) -> NSImage? {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Ghost")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        img?.isTemplate = true
        return img
    }

    /// A small progress ring for the menu bar (template, so it matches the menu bar's color)
    private func ring(_ progress: Double, paused: Bool, rest: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 15, height: 15), flipped: false) { r in
            let rect = r.insetBy(dx: 1.5, dy: 1.5)
            let c = NSPoint(x: rect.midX, y: rect.midY), radius = rect.width / 2
            NSColor.black.withAlphaComponent(0.3).setStroke()
            let track = NSBezierPath(ovalIn: rect); track.lineWidth = 1.6; track.stroke()
            let arc = NSBezierPath()
            arc.appendArc(withCenter: c, radius: radius, startAngle: 90, endAngle: 90 - 360 * CGFloat(max(0.02, progress)), clockwise: true)
            arc.lineWidth = 1.6; arc.lineCapStyle = .round
            NSColor.black.setStroke(); arc.stroke()
            NSColor.black.setFill()
            if paused {
                NSBezierPath(roundedRect: NSRect(x: c.x - 2.6, y: c.y - 2.5, width: 1.8, height: 5), xRadius: 0.9, yRadius: 0.9).fill()
                NSBezierPath(roundedRect: NSRect(x: c.x + 0.8, y: c.y - 2.5, width: 1.8, height: 5), xRadius: 0.9, yRadius: 0.9).fill()
            } else if !rest {
                NSBezierPath(ovalIn: NSRect(x: c.x - 1.5, y: c.y - 1.5, width: 3, height: 3)).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    private func refreshItem() {
        guard let b = item?.button else { return }
        let mins = Int(ceil(engine.remaining / 60))
        let style = defaults.string(forKey: Key.barStyle) ?? "ring"
        switch engine.phase {
        case .idle:
            b.image = symbol("circle.dashed"); b.title = ""
        case .ready:
            b.image = symbol("checkmark.circle"); b.title = style == "icon" ? "" : " Done"
        case .focus, .rest:
            b.image = style == "time" ? nil : ring(engine.progress, paused: engine.paused, rest: engine.phase == .rest)
            b.title = style == "icon" ? "" : (style == "time" ? "\(mins)m" : " \(mins)m")
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector?, key: String = "", mods: NSEvent.ModifierFlags = []) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: hotKeyTaken ? "" : key)
            i.keyEquivalentModifierMask = mods
            i.target = self
            i.isEnabled = action != nil
            menu.addItem(i)
        }
        let left = "\(Int(ceil(engine.remaining / 60))) min left"
        switch engine.phase {
        case .idle:
            add("Start focus…", #selector(primary), key: " ", mods: .option)
            add("Quick timer", #selector(togglePill), key: "t", mods: .option)
            if engine.lastApp != nil { add("Quick start on the app in front", #selector(quick)) }
            if !Store.shared.presets.isEmpty {
                let sub = NSMenu()
                for (i, p) in Store.shared.presets.enumerated() {
                    let it = NSMenuItem(title: p.name, action: #selector(startPreset(_:)), keyEquivalent: "")
                    it.tag = i; it.target = self
                    sub.addItem(it)
                }
                let parent = NSMenuItem(title: "Start preset", action: nil, keyEquivalent: "")
                parent.submenu = sub
                menu.addItem(parent)
            }
        case .focus:
            add(engine.paused ? "Paused · \(engine.focusName) · \(left)" : "\(engine.focusName) · \(left)", nil)
            add(engine.paused ? "Resume" : "Pause", #selector(primary), key: " ", mods: .option)
            add("Add 5 minutes", #selector(extend))
            add("Take a break now", #selector(breakNow))
            add("End round", #selector(stop), key: " ", mods: [.option, .shift])
        case .rest:
            add(engine.paused ? "Break paused · \(left)" : "On a break · \(left)", nil)
            add(engine.paused ? "Resume" : "Pause", #selector(primary), key: " ", mods: .option)
            add("Add 5 minutes", #selector(extend))
            add("Skip break", #selector(skipBreak))
            add("End", #selector(stop), key: " ", mods: [.option, .shift])
        case .ready:
            add(engine.nextIsRest ? "Focus done" : "Break's over", nil)
            add(engine.nextIsRest ? "Start break" : "Start focus", #selector(primary), key: " ", mods: .option)
            add("5 more minutes", #selector(extend))
            add("End", #selector(stop), key: " ", mods: [.option, .shift])
        }
        if engine.phase != .idle { add(pill?.isVisible == true ? "Hide timer pill" : "Show timer pill", #selector(togglePill), key: "t", mods: .option) }
        if hotKeyTaken { add("⌥ Space is used by another app", nil) }
        menu.addItem(.separator())
        add("Open Ghost", #selector(openWindow))
        add("Quit Ghost", #selector(quit))
    }

    @objc private func primary() { engine.primary() }
    @objc private func quick() { engine.quickStart() }
    @objc private func extend() { engine.extend() }
    @objc private func breakNow() { engine.breakNow() }
    @objc private func skipBreak() { engine.skipBreak() }
    @objc private func stop() { engine.stop() }
    @objc private func quit() { engine.stop(); NSApp.terminate(nil) }
    @objc private func startPreset(_ sender: NSMenuItem) {
        let ps = Store.shared.presets
        if ps.indices.contains(sender.tag) { engine.begin(ps[sender.tag]) }
    }

    // MARK: Panels

    func showStart() {
        Store.shared.refreshPlan()
        startPanel?.orderOut(nil)
        let front = engine.lastApp
        let view = StartView(frontApp: front, onStart: { [weak self] t, save in
            if save { Store.shared.savePreset(t) }
            self?.closeStart()
            self?.engine.begin(t)
            front?.activate()
        }, onCancel: { [weak self] in
            self?.closeStart()
            front?.activate()
        })
        let p = makePanel(view, keyable: true)
        startPanel = p
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
    }

    private func closeStart() { startPanel?.orderOut(nil); startPanel = nil }

    func showEnd(_ kind: EndKind) {
        endPanel?.orderOut(nil)
        let p = makePanel(EndView(kind: kind, engine: engine), keyable: false)
        endPanel = p
        p.orderFrontRegardless()
    }

    @objc func openWindow() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: GhostView(store: .shared, engine: engine)))
            w.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.backgroundColor = Theme.bgNS
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Timer pill

    @objc func togglePill() {
        if pill?.isVisible == true { hidePill() } else { showPill() }
    }

    func showPill() {
        if pill == nil { pill = makePill() }
        guard let p = pill else { return }
        p.orderFrontRegardless()
        if engine.phase == .idle { p.makeKey() }   // arrow keys and Return work without leaving your app
    }

    private func hidePill() {
        pill?.orderOut(nil)
        if engine.phase == .idle { engine.lastApp?.activate() }
    }

    /// Shows the pill when a round starts (if set to), hides it when the round ends
    private func phaseChanged() {
        let ph = engine.phase
        guard ph != lastPhase else { return }
        if ph == .idle { pill?.orderOut(nil) }
        else if lastPhase == .idle {
            if defaults.string(forKey: Key.pillDuring) == "hide" { pill?.orderOut(nil) } else { showPill() }
        }
        lastPhase = ph
    }

    private func quickTarget() -> FocusTarget {
        if let app = engine.lastApp, let id = app.bundleIdentifier {
            return FocusTarget(name: app.localizedName ?? "Focus", apps: [id], appNames: [app.localizedName ?? id])
        }
        return FocusTarget(name: "Focus")
    }

    private func makePill() -> FloatingPanel {
        let view = PillView(engine: engine, onStart: { [weak self] m in
            guard let self else { return }
            self.engine.begin(self.quickTarget(), minutes: Double(m))
            self.engine.lastApp?.activate()
        }, onClose: { [weak self] in
            self?.hidePill()
        }, onMore: { [weak self] in
            self?.pill?.orderOut(nil)
            self?.showStart()
        }, onMove: { [weak self] ended in
            self?.movePill(ended: ended)
        }, onSize: { [weak self] size in
            self?.sizePill(size)
        })
        let p = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 250, height: 40),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.keyable = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = FirstClickHost(rootView: view)
        var size = host.fittingSize                 // measure first, then size the panel by hand (it grows to the right)
        if size.width < 10 || size.height < 10 { size = NSSize(width: 248, height: 40) }
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        p.contentView = host
        p.setContentSize(size)
        p.setFrameOrigin(pillOrigin(for: size))
        return p
    }

    /// Where the pill was left, or just under the menu bar in the middle of the screen
    private func pillOrigin(for size: NSSize) -> NSPoint {
        let saved = NSPoint(x: defaults.double(forKey: Key.pillX), y: defaults.double(forKey: Key.pillY))
        if defaults.object(forKey: Key.pillX) != nil,
           NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -20, dy: -20).contains(NSRect(origin: saved, size: size)) }) {
            return saved
        }
        let vf = NSScreen.main?.visibleFrame ?? .zero
        return NSPoint(x: vf.midX - size.width / 2, y: vf.maxY - size.height - 16)
    }

    /// Grows to the right (the left edge stays put), so the grip stays under your pointer
    private func sizePill(_ size: CGSize) {
        guard let p = pill, size.width > 0, p.frame.size != size else { return }
        let top = p.frame.maxY
        p.setFrame(NSRect(x: p.frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
    }

    private func movePill(ended: Bool) {
        guard let p = pill else { return }
        if ended {
            moveStart = nil
            defaults.set(p.frame.minX, forKey: Key.pillX)
            defaults.set(p.frame.minY, forKey: Key.pillY)
            return
        }
        let mouse = NSEvent.mouseLocation
        if moveStart == nil { moveStart = (mouse, p.frame.origin) }
        guard let s = moveStart else { return }
        p.setFrameOrigin(NSPoint(x: s.origin.x + mouse.x - s.mouse.x, y: s.origin.y + mouse.y - s.mouse.y))
    }

    /// While the pill is waiting: ← → (or ↑ ↓) change the length by 5 minutes, Return starts, Esc closes
    private func watchPillKeys() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, let p = self.pill, p.isKeyWindow, p.isVisible, self.engine.phase == .idle else { return e }
            let m = defaults.integer(forKey: Key.pillMin)
            switch e.keyCode {
            case 123, 125: defaults.set(max(5, m - 5), forKey: Key.pillMin)
            case 124, 126: defaults.set(min(120, m + 5), forKey: Key.pillMin)
            case 36, 76:
                self.engine.begin(self.quickTarget(), minutes: Double(m))
                self.engine.lastApp?.activate()
            case 53: self.hidePill()
            default: return e
            }
            return nil
        }
    }

    // MARK: Hot keys (Carbon hot keys need no Accessibility permission)

    func hotKey(_ id: UInt32) {
        switch id {
        case 1: engine.primary()
        case 2: engine.stop()
        default: togglePill()
        }
    }

    private func registerHotKeys() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, ctx in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let me = Unmanaged<AppDelegate>.fromOpaque(ctx!).takeUnretainedValue()
            let id = hk.id
            DispatchQueue.main.async { MainActor.assumeIsolated { me.hotKey(id) } }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        let sig = OSType(0x47485354)
        let a = RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), EventHotKeyID(signature: sig, id: 1),
                                    GetApplicationEventTarget(), 0, &hotKeys[0])
        _ = RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey | shiftKey), EventHotKeyID(signature: sig, id: 2),
                                GetApplicationEventTarget(), 0, &hotKeys[1])
        _ = RegisterEventHotKey(UInt32(kVK_ANSI_T), UInt32(optionKey), EventHotKeyID(signature: sig, id: 3),
                                GetApplicationEventTarget(), 0, &hotKeys[2])
        hotKeyTaken = a != noErr
    }
}

// MARK: - Launch

defaults.register(defaults: [Key.focusMin: 25, Key.breakMin: 5, Key.longMin: 15, Key.roundsPerLong: 4,
                             Key.edge: "sand", Key.wander: "dim", Key.rhythm: "classic", Key.askFocus: true,
                             Key.autoBreak: false, Key.autoFocus: false, Key.sound: "Glass", Key.notify: false,
                             Key.barStyle: "ring", Key.grace: 10, Key.dim: "medium", Key.appearance: "light",
                             Key.trackSites: false, Key.pillDuring: "show", Key.pillMin: 25])

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate

    // Minimal main menu so Command-W closes the window, Command-Q quits, and copy and paste work in the panels
    let mainMenu = NSMenu(), appItem = NSMenuItem(), editItem = NSMenuItem()
    mainMenu.addItem(appItem); mainMenu.addItem(editItem)
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    appMenu.addItem(withTitle: "Quit Ghost", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    let edit = NSMenu(title: "Edit"); editItem.submenu = edit
    edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    app.mainMenu = mainMenu

    withExtendedLifetime(delegate) { app.run() }
}
