// Ghost: a minimalist pomodoro focus app that lives in the Mac menu bar.
//
// Option + Space starts a focus round with the app in front. A thin line at the screen edge
// shows the round. Leave the focus app and, after a short grace period, the screen slowly
// dims (or blurs) until you come back. Breaks follow on their own; the line refills during them.
//
// Light by design: Ghost reacts to app switches, and a single slow timer (every 2 s, with
// tolerance) runs only during a session. No polling when idle, no screen recording.

import Cocoa
import SwiftUI
import Carbon.HIToolbox
import ServiceManagement

// MARK: - Settings

enum Key {
    static let focusMin = "focusMin", breakMin = "breakMin", longMin = "longMin"
    static let roundsPerLong = "roundsPerLong", edge = "edge", wander = "wander"
}

let defaults = UserDefaults.standard

// MARK: - Stats storage

struct Round: Codable {
    var start: Date
    var focus: Double   // seconds spent in the focus app
    var away: Double    // seconds spent elsewhere
    var app: String     // name of the focus app
    var done: Bool      // true if the round ran to the end
}

@MainActor final class Store: ObservableObject {
    static let shared = Store()
    @Published private(set) var rounds: [Round] = []

    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ghost", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("rounds.json")
    }()

    init() {
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([Round].self, from: data) { rounds = saved }
    }

    func add(_ round: Round) {
        rounds.append(round)
        if let data = try? JSONEncoder().encode(rounds) { try? data.write(to: url, options: .atomic) }
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

/// The thin line along the top (Sand) or bottom (Tide) edge of the main screen.
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
        var color = NSColor.labelColor.cgColor
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance { color = NSColor.labelColor.cgColor }
        bar.backgroundColor = color
        CATransaction.commit()
        window?.orderFrontRegardless()
    }

    /// Length from 0 (empty) to 1 (full width). Small steps get the layer's default short animation.
    func set(_ value: Double) {
        bar.setValue(min(1, max(0, value)), forKeyPath: "transform.scale.x")
    }

    func hide() { window?.orderOut(nil) }
}

/// The dim or blur that slowly covers the screen while you are away from the focus app.
@MainActor final class Veil {
    private var windows: [NSWindow] = []

    func show(blur: Bool) {
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
        let target: CGFloat = blur ? 0.97 : 0.6
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
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.4
            for w in ws { w.animator().alphaValue = 0 }
        }, completionHandler: {
            for w in ws { w.orderOut(nil) }
        })
    }
}

/// A small message near the top of the screen that fades after a few seconds.
@MainActor final class Toast {
    private var window: NSWindow?

    func show(_ text: String) {
        window?.orderOut(nil)
        guard let screen = NSScreen.main else { return }
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + 32, height: 34)
        let vf = screen.visibleFrame
        let frame = NSRect(x: vf.midX - size.width / 2, y: vf.maxY - size.height - 20,
                           width: size.width, height: size.height)
        let w = makeOverlay(frame, level: overlayLevel)
        let v = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = 10
        v.layer?.masksToBounds = true
        label.frame.origin = NSPoint(x: 16, y: (size.height - label.frame.height) / 2)
        v.addSubview(label)
        w.contentView = v
        w.alphaValue = 0
        w.orderFrontRegardless()
        window = w
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; w.animator().alphaValue = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            MainActor.assumeIsolated {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.5
                    w.animator().alphaValue = 0
                }, completionHandler: {
                    w.orderOut(nil)
                    MainActor.assumeIsolated { if self?.window === w { self?.window = nil } }
                })
            }
        }
    }
}

func minutesText(_ seconds: Double) -> String { "\(Int((seconds / 60).rounded())) min" }

// MARK: - The focus engine

@MainActor final class Engine {
    enum Phase { case idle, focus, rest }

    private(set) var phase = Phase.idle
    private(set) var focusName = ""
    var onChange: (() -> Void)?

    private var lastApp: NSRunningApplication?
    private var focusBundle = ""
    private var start = Date(), end = Date(), lastTick = Date()
    private var awaySince: Date?
    private var awayTotal = 0.0
    private var tide = 0.0
    private var roundsInCycle = 0
    private var ticker: Timer?, grace: Timer?
    private let line = EdgeLine(), veil = Veil(), toast = Toast()
    private let myID = Bundle.main.bundleIdentifier

    var remaining: TimeInterval { max(0, end.timeIntervalSinceNow) }

    init() {
        let ws = NSWorkspace.shared
        if let front = ws.frontmostApplication, front.bundleIdentifier != myID { lastApp = front }
        ws.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                          object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.activated(app) }
        }
        ws.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification,
                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    func toggle() { phase == .idle ? beginFocus(with: lastApp) : stop() }

    func skipBreak() { if phase == .rest { beginFocus(with: nil) } }

    func stop() {
        guard phase != .idle else { return }
        if phase == .focus {
            let (f, a) = record(done: false)
            toast.show("Stopped  ·  \(minutesText(f)) focused  ·  \(minutesText(a)) away")
        } else {
            toast.show("Stopped")
        }
        clearAway()
        ticker?.invalidate(); ticker = nil
        line.hide()
        phase = .idle
        roundsInCycle = 0
        onChange?()
    }

    // MARK: Phases

    private func seconds(_ key: String) -> Double { Double(max(1, defaults.integer(forKey: key))) * 60 }

    private func beginFocus(with app: NSRunningApplication?) {
        if let app, let id = app.bundleIdentifier {
            focusBundle = id
            focusName = app.localizedName ?? "your app"
        }
        guard !focusBundle.isEmpty else {
            toast.show("Click into the app you want to focus on, then press ⌥ Space")
            return
        }
        phase = .focus
        start = Date()
        end = start.addingTimeInterval(seconds(Key.focusMin))
        lastTick = start
        awaySince = nil
        awayTotal = 0
        tide = 0
        clearAway()
        showLine()
        startTicker()
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if front != focusBundle && front != myID { leave() }
        onChange?()
    }

    private func finishFocus() {
        let (f, a) = record(done: true)
        clearAway()
        roundsInCycle += 1
        let long = roundsInCycle % max(1, defaults.integer(forKey: Key.roundsPerLong)) == 0
        let restKey = long ? Key.longMin : Key.breakMin
        NSSound(named: "Glass")?.play()
        toast.show("\(minutesText(f)) focused  ·  \(minutesText(a)) away  ·  \(long ? "Long break" : "Break") \(defaults.integer(forKey: restKey)) min")
        phase = .rest
        start = Date()
        end = start.addingTimeInterval(seconds(restKey))
        lastTick = start
        showLine()
        onChange?()
    }

    private func finishRest() {
        NSSound(named: "Glass")?.play()
        toast.show("Back to \(focusName)")
        beginFocus(with: nil)
    }

    /// Saves the round (if it lasted at least a minute) and returns (focused, away) seconds.
    private func record(done: Bool) -> (Double, Double) {
        let now = min(Date(), end)
        let away = awayTotal + (awaySince.map { max(0, now.timeIntervalSince($0)) } ?? 0)
        let focus = max(0, now.timeIntervalSince(start) - away)
        if focus + away >= 60 {
            Store.shared.add(Round(start: start, focus: focus, away: away, app: focusName, done: done))
        }
        return (focus, away)
    }

    // MARK: Away and back

    private func activated(_ app: NSRunningApplication) {
        if app.bundleIdentifier == myID { return }   // opening Ghost's own window doesn't count
        lastApp = app
        guard phase == .focus else { return }
        if app.bundleIdentifier == focusBundle { comeBack() } else { leave() }
    }

    private func leave() {
        guard awaySince == nil else { return }
        awaySince = Date()
        grace = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.veil.show(blur: defaults.string(forKey: Key.wander) == "blur") }
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
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func tick() {
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now
        if phase == .focus {
            // Tide grows while you stay, and washes back three times as fast while you're away.
            tide += (awaySince == nil ? dt : -3 * dt) / end.timeIntervalSince(start)
            tide = min(1, max(0, tide))
        }
        if now >= end {
            if phase == .focus { finishFocus() } else { finishRest() }
            return
        }
        updateLine()
        onChange?()
    }

    private var edge: String { defaults.string(forKey: Key.edge) ?? "sand" }

    private func showLine() {
        if edge == "none" { line.hide(); return }
        line.show(atTop: edge == "sand")
        updateLine()
    }

    private func updateLine() {
        let left = remaining / end.timeIntervalSince(start)
        switch phase {
        case .focus: line.set(edge == "tide" ? tide : left)
        case .rest: line.set(1 - left)   // the line refills during a break
        case .idle: break
        }
    }
}

// MARK: - Stats for the window

struct Stats {
    struct Day: Identifiable { let id: Int; let label: String; let minutes: Double }
    struct AppRow: Identifiable { var id: String { name }; let name: String; let minutes: Int }

    var todayMin = 0, todayRounds = 0, todayAway = 0
    var streak = 0, score = 0, weekMin = 0
    var week: [Day] = []
    var apps: [AppRow] = []
    var weekMax: Double { week.map(\.minutes).max() ?? 0 }

    init(_ rounds: [Round]) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var byDay: [Date: Double] = [:]
        var doneDays = Set<Date>()
        for r in rounds {
            let d = cal.startOfDay(for: r.start)
            byDay[d, default: 0] += r.focus
            if r.done { doneDays.insert(d) }
        }

        let todays = rounds.filter { cal.isDate($0.start, inSameDayAs: today) }
        todayMin = Int(todays.reduce(0) { $0 + $1.focus } / 60)
        todayAway = Int((todays.reduce(0) { $0 + $1.away } / 60).rounded())
        todayRounds = todays.filter(\.done).count

        let letter = DateFormatter()
        letter.dateFormat = "EEEEE"
        for i in (0..<7).reversed() {
            let d = cal.date(byAdding: .day, value: -i, to: today)!
            week.append(Day(id: i, label: letter.string(from: d), minutes: (byDay[d] ?? 0) / 60))
        }

        var day = doneDays.contains(today) ? today : cal.date(byAdding: .day, value: -1, to: today)!
        while doneDays.contains(day) {
            streak += 1
            day = cal.date(byAdding: .day, value: -1, to: day)!
        }

        let weekStart = cal.date(byAdding: .day, value: -6, to: today)!
        let recent = rounds.filter { $0.start >= weekStart }
        let focus = recent.reduce(0) { $0 + $1.focus }, away = recent.reduce(0) { $0 + $1.away }
        weekMin = Int(focus / 60)
        score = focus + away > 0 ? Int((100 * focus / (focus + away)).rounded()) : 0
        var perApp: [String: Double] = [:]
        for r in recent { perApp[r.app, default: 0] += r.focus }
        apps = perApp.sorted { $0.value > $1.value }.prefix(3).map { AppRow(name: $0.key, minutes: Int($0.value / 60)) }
    }
}

// MARK: - Window UI

struct GhostView: View {
    @ObservedObject var store: Store
    @State private var tab = 0
    @AppStorage(Key.focusMin) private var focusMin = 25
    @AppStorage(Key.breakMin) private var breakMin = 5
    @AppStorage(Key.longMin) private var longMin = 15
    @AppStorage(Key.roundsPerLong) private var roundsPerLong = 4
    @AppStorage(Key.edge) private var edge = "sand"
    @AppStorage(Key.wander) private var wander = "dim"
    @State private var atLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Stats").tag(0)
                Text("Settings").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 170)
            .padding(.top, 34)

            Group {
                if tab == 0 { stats } else { settings }
            }
            .padding(.horizontal, 26)
            .padding(.top, 26)

            Spacer(minLength: 0)
        }
        .frame(width: 320, height: 470)
    }

    private var stats: some View {
        let s = Stats(store.rounds)
        return VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Today").font(.caption).foregroundStyle(.secondary)
                Text("\(s.todayMin) min").font(.system(size: 40, weight: .semibold)).monospacedDigit()
                Text("\(s.todayRounds) \(s.todayRounds == 1 ? "round" : "rounds")  ·  \(s.todayAway) min away")
                    .font(.callout).foregroundStyle(.secondary)
            }

            HStack(alignment: .bottom, spacing: 0) {
                ForEach(s.week) { d in
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(d.id == 0 ? Color.primary : Color.primary.opacity(0.22))
                            .frame(width: 18, height: max(2, 72 * d.minutes / max(1, s.weekMax)))
                        Text(d.label).font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 92, alignment: .bottom)

            HStack(spacing: 0) {
                metric("Streak", "\(s.streak) d")
                metric("Focus", "\(s.score)%")
                metric("7 days", String(format: "%.1f h", Double(s.weekMin) / 60))
            }

            if !s.apps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Top apps").font(.caption).foregroundStyle(.secondary)
                    ForEach(s.apps) { a in
                        HStack {
                            Text(a.name).lineLimit(1)
                            Spacer()
                            Text("\(a.minutes) min").monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.medium)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepper("Focus", $focusMin, 5...120, 5, "min")
            stepper("Break", $breakMin, 1...30, 1, "min")
            stepper("Long break", $longMin, 5...60, 5, "min")
            stepper("Long break every", $roundsPerLong, 2...8, 1, "")
            Divider().padding(.vertical, 4)
            HStack {
                Text("Edge line")
                Spacer()
                Picker("", selection: $edge) {
                    Text("Sand").tag("sand")
                    Text("Tide").tag("tide")
                    Text("None").tag("none")
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 160)
            }
            HStack {
                Text("When you wander")
                Spacer()
                Picker("", selection: $wander) {
                    Text("Dim").tag("dim")
                    Text("Blur").tag("blur")
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 106)
            }
            Divider().padding(.vertical, 4)
            Toggle("Open at login", isOn: $atLogin)
                .onChange(of: atLogin) { _, on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        atLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            Text("⌥ Space starts or stops a round.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.top, 6)
        }
    }

    private func stepper(_ title: String, _ value: Binding<Int>, _ range: ClosedRange<Int>,
                         _ step: Int, _ unit: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(unit.isEmpty ? "\(value.wrappedValue)" : "\(value.wrappedValue) \(unit)")
                .monospacedDigit().foregroundStyle(.secondary)
            Stepper("", value: value, in: range, step: step).labelsHidden()
        }
    }
}

// MARK: - App: menu bar item, menu, window, hotkey

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let engine = Engine()
    private var item: NSStatusItem!
    private var window: NSWindow?
    private var hotKey: EventHotKeyRef?
    private var hotKeyTaken = false

    func applicationDidFinishLaunching(_ note: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        item.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        item.button?.imagePosition = .imageLeading
        engine.onChange = { [weak self] in self?.refreshItem() }
        refreshItem()
        registerHotKey()
    }

    // Opening Ghost again (from Applications or Spotlight) shows its window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openWindow()
        return false
    }

    private func symbol(_ name: String) -> NSImage? {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Ghost")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        img?.isTemplate = true
        return img
    }

    private func refreshItem() {
        guard let b = item.button else { return }
        let mins = Int(ceil(engine.remaining / 60))
        switch engine.phase {
        case .idle:
            b.image = symbol("circle.dashed"); b.title = ""
        case .focus:
            b.image = symbol("circle.inset.filled"); b.title = " \(mins)m"
        case .rest:
            b.image = symbol("circle"); b.title = " \(mins)m"
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // `shortcut` shows the global ⌥Space on the right, drawn by macOS like any menu shortcut.
        func add(_ title: String, _ action: Selector?, shortcut: Bool = false) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: shortcut ? " " : "")
            if shortcut { i.keyEquivalentModifierMask = .option }
            i.target = self
            i.isEnabled = action != nil
            menu.addItem(i)
        }
        switch engine.phase {
        case .idle:
            add("Start focus", #selector(toggle), shortcut: !hotKeyTaken)
        case .focus:
            add("Focusing on \(engine.focusName)", nil)
            add("Stop", #selector(toggle), shortcut: !hotKeyTaken)
        case .rest:
            add("On a break", nil)
            add("Skip break", #selector(skipBreak))
            add("Stop", #selector(toggle), shortcut: !hotKeyTaken)
        }
        if hotKeyTaken { add("⌥ Space is used by another app", nil) }
        menu.addItem(.separator())
        add("Open Ghost", #selector(openWindow))
        add("Quit Ghost", #selector(quit))
    }

    @objc private func toggle() { engine.toggle() }
    @objc private func skipBreak() { engine.skipBreak() }
    @objc private func quit() { engine.stop(); NSApp.terminate(nil) }

    @objc func openWindow() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: GhostView(store: .shared)))
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, ctx in
            let me = Unmanaged<AppDelegate>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { me.engine.toggle() } }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        let status = RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey),
                                         EventHotKeyID(signature: OSType(0x47485354), id: 1),
                                         GetApplicationEventTarget(), 0, &hotKey)
        hotKeyTaken = status != noErr
    }
}

// MARK: - Launch

defaults.register(defaults: [Key.focusMin: 25, Key.breakMin: 5, Key.longMin: 15,
                             Key.roundsPerLong: 4, Key.edge: "sand", Key.wander: "dim"])

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate

    // Minimal main menu so Command-W closes the window and Command-Q quits while it's open.
    let mainMenu = NSMenu(), appItem = NSMenuItem()
    mainMenu.addItem(appItem)
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    appMenu.addItem(withTitle: "Quit Ghost", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    app.mainMenu = mainMenu

    withExtendedLifetime(delegate) { app.run() }
}
