//
//  clear_atticApp.swift
//  clear attic
//
//  Created by Balaji K on 03/04/26.
//

import SwiftUI
import AppKit
import Combine
import ServiceManagement
import UserNotifications

// MARK: - Helpers

nonisolated func formatBytes(_ bytes: Int64) -> String {
    let val = Double(bytes)
    if val >= 1_073_741_824 { return String(format: "%.1f GB", val / 1_073_741_824) }
    if val >= 1_048_576 { return String(format: "%.1f MB", val / 1_048_576) }
    return String(format: "%.0f KB", val / 1024)
}

nonisolated func makeMenuBarIcon() -> NSImage {
    let cfg = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
    if let img = NSImage(systemSymbolName: "broom.fill", accessibilityDescription: "Clear Attic")?
        .withSymbolConfiguration(cfg) {
        img.isTemplate = true
        return img
    }
    let fallback = NSImage(systemSymbolName: "archivebox", accessibilityDescription: "Clear Attic") ?? NSImage()
    fallback.isTemplate = true
    return fallback
}

// MARK: - Models

nonisolated enum ItemCategory: String, CaseIterable, Sendable {
    case dust = "Dust"
    case oldNotes = "Old Notes"
    case blueprints = "Blueprints"
    case toyModels = "Toy Models"
    case forgottenBoxes = "Forgotten Boxes"
    case packedBags = "Packed Bags"
    case junkPile = "Junk Pile"
}

nonisolated struct ScanItem: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let url: URL
    let category: ItemCategory
    let size: Int64
    var isSelected: Bool
    let isDirectory: Bool
}

nonisolated enum AppPhase: Hashable, Sendable {
    case idle, scanning, results, done
}

// MARK: - View Model

nonisolated class AtticVM: ObservableObject {
    @Published var phase: AppPhase = .idle
    @Published var items: [ScanItem] = []
    @Published var scannedCount = 0
    @Published var totalFreed: Int64 = 0
    @Published var demoMode = false
    @Published var launchAtLogin = false
    @Published var autoCleanEnabled = false
    @Published var autoCleanDay = 1
    @Published var autoCleanHour = 21
    @Published var autoCleanExpanded = false

    private let threshold: Int64 = 100 * 1024 * 1024
    private var generation = 0
    private var cancellables = Set<AnyCancellable>()

    static let days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    static func hourLabel(_ h: Int) -> String {
        if h == 0 { return "12 AM" }; if h < 12 { return "\(h) AM" }
        if h == 12 { return "12 PM" }; return "\(h - 12) PM"
    }
    var scheduleText: String { "\(Self.days[autoCleanDay - 1]) \(Self.hourLabel(autoCleanHour))" }

    private static func gb(_ v: Double) -> Int64 { Int64(v * 1_073_741_824) }
    private static func mb(_ v: Double) -> Int64 { Int64(v * 1_048_576) }
    private static let dummyURL = URL(fileURLWithPath: "/tmp/clearattic-demo")

    static let demoItems: [ScanItem] = [
        ScanItem(name: "Adobe Cache",       url: dummyURL, category: .dust,           size: gb(486.3), isSelected: true,  isDirectory: true),
        ScanItem(name: "node_modules",      url: dummyURL, category: .forgottenBoxes, size: gb(12.4),  isSelected: true,  isDirectory: true),
        ScanItem(name: "Xcode DerivedData", url: dummyURL, category: .blueprints,     size: gb(4.2),   isSelected: true,  isDirectory: true),
        ScanItem(name: "Backup_2023.dmg",   url: dummyURL, category: .packedBags,     size: gb(8.1),   isSelected: true,  isDirectory: false),
        ScanItem(name: "iOS Simulators",    url: dummyURL, category: .toyModels,      size: gb(3.9),   isSelected: false, isDirectory: true),
        ScanItem(name: "Homebrew",          url: dummyURL, category: .dust,           size: mb(131),   isSelected: true,  isDirectory: true),
        ScanItem(name: "pip cache",         url: dummyURL, category: .dust,           size: mb(389),   isSelected: true,  isDirectory: true),
        ScanItem(name: "Spotify Cache",     url: dummyURL, category: .dust,           size: gb(1.3),   isSelected: true,  isDirectory: true),
        ScanItem(name: "Old Logs",          url: dummyURL, category: .oldNotes,       size: mb(240),   isSelected: true,  isDirectory: true),
    ]

    var selectedSize: Int64 { items.filter(\.isSelected).reduce(0) { $0 + $1.size } }
    var selectedCount: Int { items.filter(\.isSelected).count }

    init() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        autoCleanEnabled = UserDefaults.standard.bool(forKey: "autoClean")
        autoCleanDay = UserDefaults.standard.object(forKey: "autoCleanDay") as? Int ?? 1
        autoCleanHour = UserDefaults.standard.object(forKey: "autoCleanHour") as? Int ?? 21

        $launchAtLogin.dropFirst().sink { val in
            if val { try? SMAppService.mainApp.register() }
            else { try? SMAppService.mainApp.unregister() }
        }.store(in: &cancellables)
        $autoCleanEnabled.dropFirst().sink { val in
            UserDefaults.standard.set(val, forKey: "autoClean")
            if val { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
        }.store(in: &cancellables)
        $autoCleanDay.dropFirst().sink { UserDefaults.standard.set($0, forKey: "autoCleanDay") }.store(in: &cancellables)
        $autoCleanHour.dropFirst().sink { UserDefaults.standard.set($0, forKey: "autoCleanHour") }.store(in: &cancellables)

        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.checkAutoClean()
        }
    }

    func syncLaunchAtLogin() { launchAtLogin = SMAppService.mainApp.status == .enabled }

    func goIdle() {
        generation += 1
        phase = .idle; items = []; scannedCount = 0; totalFreed = 0; autoCleanExpanded = false
    }

    func scan() {
        if demoMode { demoScan(); return }
        generation += 1; let gen = generation
        phase = .scanning; scannedCount = 0; items = []; totalFreed = 0
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.runScan(gen: gen) }
    }

    private func demoScan() {
        phase = .scanning; scannedCount = 0; items = []; totalFreed = 0
        var count = 0
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            count += Int.random(in: 40...80)
            self.scannedCount = count
            if count >= 2400 { timer.invalidate(); self.items = Self.demoItems; self.phase = .results }
        }
    }

    func selectAll()  { for i in items.indices { items[i].isSelected = true } }
    func selectNone() { for i in items.indices { items[i].isSelected = false } }
    func toggle(_ id: UUID) {
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].isSelected.toggle() }
    }

    func clear() {
        if demoMode { totalFreed = Int64(510.7 * 1_073_741_824); phase = .done; scheduleDoneReset(); return }
        let doomed = items.filter(\.isSelected)
        guard !doomed.isEmpty else { return }
        totalFreed = doomed.reduce(0) { $0 + $1.size }
        phase = .done
        scheduleDoneReset()
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            for item in doomed {
                do { try fm.trashItem(at: item.url, resultingItemURL: nil) }
                catch { try? fm.removeItem(at: item.url) }
            }
        }
    }

    private func scheduleDoneReset() {
        // Play completion chime
        if let glass = NSSound(named: NSSound.Name("Glass")) { glass.play() }
        else { NSSound.beep() }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.phase == .done else { return }
            self.goIdle()
        }
    }

    // MARK: Auto-Clean

    private func checkAutoClean() {
        guard autoCleanEnabled else { return }
        let cal = Calendar.current, now = Date()
        guard cal.component(.weekday, from: now) == autoCleanDay,
              cal.component(.hour, from: now) == autoCleanHour else { return }
        let today = cal.startOfDay(for: now)
        let last = UserDefaults.standard.object(forKey: "lastAutoClean") as? Date ?? .distantPast
        guard cal.startOfDay(for: last) != today else { return }
        UserDefaults.standard.set(now, forKey: "lastAutoClean")
        DispatchQueue.global(qos: .background).async { [weak self] in self?.performAutoClean() }
    }

    private func performAutoClean() {
        let found = Self.collectItems(threshold: threshold)
        let toDelete = found.filter(\.isSelected)
        guard !toDelete.isEmpty else { return }
        var freed: Int64 = 0
        let fm = FileManager.default
        for item in toDelete {
            do { try fm.trashItem(at: item.url, resultingItemURL: nil); freed += item.size }
            catch { do { try fm.removeItem(at: item.url); freed += item.size } catch {} }
        }
        if freed > 0 { sendNotification(freed: freed) }
    }

    private func sendNotification(freed: Int64) {
        let c = UNMutableNotificationContent()
        c.title = "Clear Attic"; c.body = "Attic cleared. \(formatBytes(freed)) freed."; c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    // MARK: Scan Logic

    static func collectItems(threshold: Int64, shouldStop: @escaping () -> Bool = { false },
                             onTick: @escaping () -> Void = {}) -> [ScanItem] {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory())
        var found: [ScanItem] = []

        func dirSize(_ url: URL) -> Int64 {
            guard let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return 0 }
            var t: Int64 = 0
            for case let f as URL in e {
                if shouldStop() { return t }
                if let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                   v.isRegularFile == true { t += Int64(v.fileSize ?? 0) }
            }
            return t
        }
        func fsize(_ url: URL) -> Int64 {
            (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        }
        func add(_ url: URL, _ cat: ItemCategory, dir: Bool, sel: Bool = true) {
            let sz = dir ? dirSize(url) : fsize(url)
            if sz >= threshold {
                found.append(ScanItem(name: url.lastPathComponent, url: url, category: cat,
                                      size: sz, isSelected: sel, isDirectory: dir))
            }
        }
        func scanDir(_ rel: String, _ cat: ItemCategory) {
            let dir = home.appendingPathComponent(rel)
            guard let list = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
            for item in list {
                if shouldStop() { return }; onTick()
                var d: ObjCBool = false
                fm.fileExists(atPath: item.path, isDirectory: &d)
                add(item, cat, dir: d.boolValue)
            }
        }

        scanDir("Library/Caches", .dust)
        scanDir("Library/Logs", .oldNotes)
        for r in ["Library/Developer/Xcode/DerivedData", "Library/Developer/Xcode/Archives"] {
            if shouldStop() { break }; scanDir(r, .blueprints)
        }
        let sim = home.appendingPathComponent("Library/Developer/CoreSimulator/Devices")
        if fm.fileExists(atPath: sim.path) { onTick(); add(sim, .toyModels, dir: true, sel: false) }

        for root in ["Documents", "Projects", "Developer", "Code", "Sites", "Desktop", "src"] {
            if shouldStop() { break }
            let r = home.appendingPathComponent(root)
            if fm.fileExists(atPath: r.path) { findNM(in: r, depth: 0, threshold: threshold, shouldStop: shouldStop, onTick: onTick, fm: fm, found: &found) }
        }

        let exts = Set(["dmg", "pkg", "zip"])
        if let list = try? fm.contentsOfDirectory(at: home.appendingPathComponent("Downloads"), includingPropertiesForKeys: nil) {
            for item in list where !shouldStop() {
                if exts.contains(item.pathExtension.lowercased()) { onTick(); add(item, .packedBags, dir: false) }
            }
        }
        let trash = home.appendingPathComponent(".Trash")
        if fm.fileExists(atPath: trash.path) { onTick(); add(trash, .junkPile, dir: true) }

        found.sort { $0.size > $1.size }
        return found
    }

    static func findNM(in url: URL, depth: Int, threshold: Int64,
                       shouldStop: @escaping () -> Bool, onTick: @escaping () -> Void,
                       fm: FileManager, found: inout [ScanItem]) {
        guard depth <= 4, !shouldStop() else { return }
        guard let list = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles]) else { return }
        for item in list {
            if shouldStop() { return }
            var d: ObjCBool = false
            guard fm.fileExists(atPath: item.path, isDirectory: &d), d.boolValue else { continue }
            if item.lastPathComponent == "node_modules" {
                onTick()
                var t: Int64 = 0
                if let e = fm.enumerator(at: item, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
                    for case let f as URL in e where !shouldStop() {
                        if let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                           v.isRegularFile == true { t += Int64(v.fileSize ?? 0) }
                    }
                }
                if t >= threshold {
                    found.append(ScanItem(name: "node_modules", url: item, category: .forgottenBoxes,
                                          size: t, isSelected: true, isDirectory: true))
                }
            } else if item.lastPathComponent != ".git" {
                findNM(in: item, depth: depth + 1, threshold: threshold, shouldStop: shouldStop,
                       onTick: onTick, fm: fm, found: &found)
            }
        }
    }

    private func runScan(gen: Int) {
        let found = Self.collectItems(
            threshold: threshold,
            shouldStop: { [weak self] in self?.generation != gen },
            onTick: { [weak self] in DispatchQueue.main.async { self?.scannedCount += 1 } }
        )
        guard generation == gen else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == gen else { return }
            self.items = found; self.phase = .results
        }
    }
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    var viewModel: AtticVM?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let vm = AtticVM()
        self.viewModel = vm

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = makeMenuBarIcon()
            button.toolTip = "Clear Attic"
            button.action = #selector(togglePopover)
            button.target = self
        }

        let pop = NSPopover()
        pop.contentSize = NSSize(width: 223, height: 240)
        pop.behavior = .transient
        pop.appearance = NSAppearance(named: .darkAqua)
        pop.contentViewController = NSHostingController(rootView: PopoverRoot(vm: vm))
        self.popover = pop
    }

    @objc func togglePopover() {
        guard let button = statusItem?.button, let pop = popover else { return }
        if pop.isShown { pop.performClose(nil) }
        else {
            viewModel?.syncLaunchAtLogin()
            pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            pop.contentViewController?.view.window?.makeKey()
        }
    }
}

// MARK: - Entry Point

@main
struct ClearAtticApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene { Settings { EmptyView() } }
}

// MARK: - Root View

struct PopoverRoot: View {
    @ObservedObject var vm: AtticVM

    private var fixedHeight: CGFloat? {
        switch vm.phase {
        case .idle:     return nil  // content-sized
        case .scanning: return 180
        case .results:
            if vm.items.isEmpty { return 160 }
            let rows = min(vm.items.count, 8)
            return min(CGFloat(40 + rows * 34 + 50), 380)
        case .done: return 200
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            switch vm.phase {
            case .idle:     IdleView(vm: vm).transition(.opacity)
            case .scanning: ScanningView(vm: vm).transition(.opacity)
            case .results:  ResultsView(vm: vm).transition(.opacity)
            case .done:     DoneView(vm: vm).transition(.opacity)
            }
        }
        .frame(width: 223, height: fixedHeight)
        .animation(.easeInOut(duration: 0.25), value: vm.phase)
        .animation(.easeInOut(duration: 0.15), value: vm.autoCleanExpanded)
        .background {
            VStack {
                Button("") { vm.scan() }.keyboardShortcut("s", modifiers: .command)
                Button("") { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
            }
            .frame(width: 0, height: 0).opacity(0)
        }
    }
}

// MARK: - Shared Components

struct BackHeader: View {
    let onBack: () -> Void
    var body: some View {
        HStack {
            Button(action: onBack) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Back")
                        .font(.system(size: 11))
                }
                .foregroundColor(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

struct ShortcutLabel: View {
    let key: String
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "command")
                .font(.system(size: 9))
            Text(key)
                .font(.system(size: 10.4))
        }
        .foregroundColor(.white.opacity(0.4))
    }
}

struct MiniToggle: View {
    @Binding var isOn: Bool
    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            RoundedRectangle(cornerRadius: 25)
                .fill(isOn ? Color.white.opacity(0.35) : Color.white.opacity(0.15))
                .frame(width: 18, height: 10)
            Circle()
                .fill(Color.white)
                .frame(width: 8, height: 8)
                .padding(.horizontal, 1)
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { isOn.toggle() } }
    }
}

// MARK: - Idle View (Figma spec)

struct IdleView: View {
    @ObservedObject var vm: AtticVM
    @State private var hoveredRow: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 1. Scan Attic
            idleRow("scan") {
                vm.scan()
            } label: {
                Text("Scan Attic").font(.system(size: 12))
                Spacer()
                ShortcutLabel(key: "S")
            }

            // 2. Auto Clean
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { vm.autoCleanExpanded.toggle() }
                } label: {
                    HStack {
                        Text("Auto Clean").font(.system(size: 12))
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .trailing) {
                    if vm.autoCleanExpanded {
                        MiniToggle(isOn: $vm.autoCleanEnabled)
                    }
                }

                if vm.autoCleanExpanded {
                    HStack(spacing: 6) {
                        Picker("", selection: $vm.autoCleanDay) {
                            ForEach(1...7, id: \.self) { Text(AtticVM.days[$0 - 1]).tag($0) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Picker("", selection: $vm.autoCleanHour) {
                            ForEach(0..<24, id: \.self) { Text(AtticVM.hourLabel($0)).tag($0) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .controlSize(.small)
                } else {
                    Text(vm.autoCleanEnabled ? "on - \(vm.scheduleText)" : "off")
                        .font(.system(size: 8))
                        .foregroundColor(.white.opacity(0.6))
                        .padding(.leading, 2)
                }
            }

            // 3. Launch at Login
            HStack {
                Text("Launch at Login").font(.system(size: 12))
                Spacer()
                MiniToggle(isOn: $vm.launchAtLogin)
            }

            // 4. Show how it works (runs demo scan)
            idleRow("howitworks") {
                vm.demoMode = true
                vm.scan()
            } label: {
                Text("Show how it works").font(.system(size: 12))
            }

            // 5. Quit
            idleRow("quit") {
                NSApp.terminate(nil)
            } label: {
                Text("Quit").font(.system(size: 12))
                Spacer()
                ShortcutLabel(key: "Q")
            }
        }
        .foregroundColor(.white)
        .padding(.vertical, 20)
        .padding(.horizontal, 20)
    }

    private func idleRow<Label: View>(_ id: String, action: @escaping () -> Void,
                                       @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            HStack { label() }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Scanning

struct ScanningView: View {
    @ObservedObject var vm: AtticVM
    var body: some View {
        VStack(spacing: 0) {
            BackHeader(onBack: vm.goIdle)
            Spacer()
            VStack(spacing: 12) {
                ProgressView()
                    .scaleEffect(0.9)
                    .tint(.white.opacity(0.6))
                Text("Poking around the attic…")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.8))
                Text("\(vm.scannedCount.formatted()) items checked")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
                    .monospacedDigit()
            }
            Spacer()
        }
    }
}

// MARK: - Results

struct ResultsView: View {
    @ObservedObject var vm: AtticVM

    var body: some View {
        VStack(spacing: 0) {
            BackHeader(onBack: vm.goIdle)

            if vm.items.isEmpty {
                Spacer()
                Text("Nothing dusty up here.")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(vm.items) { item in
                            ResultRow(item: item) { vm.toggle(item.id) }
                        }
                    }
                }

                // Clear All button
                Button {
                    vm.clear()
                } label: {
                    Text("Clear All")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(vm.selectedCount > 0 ? .red : .white.opacity(0.3))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(vm.selectedCount == 0)
                .padding(.vertical, 10)
            }
        }
    }
}

struct ResultRow: View {
    let item: ScanItem
    let onToggle: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Image(systemName: item.isSelected ? "checkmark.square.fill" : "square")
                    .foregroundColor(item.isSelected ? .white : .white.opacity(0.3))
                    .font(.system(size: 12))
                Text(item.name)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(formatBytes(item.size))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
                    .monospacedDigit()
            }
            .padding(.horizontal, 20)
            .frame(height: 34)
            .background(hovered ? Color.white.opacity(0.06) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// MARK: - Done

struct DoneView: View {
    @ObservedObject var vm: AtticVM

    var body: some View {
        VStack(spacing: 0) {
            BackHeader(onBack: vm.goIdle)
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.green)
                Text("Attic cleared.")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.7))
                Text(formatBytes(vm.totalFreed))
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
                Text("freed")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
            }
            Spacer()
        }
    }
}
