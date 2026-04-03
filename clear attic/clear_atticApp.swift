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

// MARK: - Menu Bar Icon

nonisolated func makeMenuBarIcon() -> NSImage {
    let cfg = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
    if let img = NSImage(systemSymbolName: "broom.fill", accessibilityDescription: "Clear Attic")?
        .withSymbolConfiguration(cfg) {
        img.isTemplate = true
        return img
    }
    // Fallback for older systems
    let fallback = NSImage(systemSymbolName: "archivebox", accessibilityDescription: "Clear Attic")
        ?? NSImage()
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
    @Published var autoCleanDay = 1      // 1=Sunday … 7=Saturday
    @Published var autoCleanHour = 21    // 9 PM

    private let threshold: Int64 = 100 * 1024 * 1024
    private var generation = 0
    private var cancellables = Set<AnyCancellable>()

    static let days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    static func hourLabel(_ h: Int) -> String {
        if h == 0 { return "12 AM" }
        if h < 12 { return "\(h) AM" }
        if h == 12 { return "12 PM" }
        return "\(h - 12) PM"
    }
    var scheduleText: String { "\(Self.days[autoCleanDay - 1]) \(Self.hourLabel(autoCleanHour))" }

    // MARK: Demo data

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

    // MARK: Init

    init() {
        // Restore persisted settings
        launchAtLogin = SMAppService.mainApp.status == .enabled
        autoCleanEnabled = UserDefaults.standard.bool(forKey: "autoClean")
        autoCleanDay = UserDefaults.standard.object(forKey: "autoCleanDay") as? Int ?? 1
        autoCleanHour = UserDefaults.standard.object(forKey: "autoCleanHour") as? Int ?? 21

        // Persist changes
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

        // Auto-clean timer — check every 60s
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.checkAutoClean()
        }
    }

    func syncLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Actions

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
        if demoMode { totalFreed = Int64(510.7 * 1_073_741_824); phase = .done; return }
        let doomed = items.filter(\.isSelected)
        guard !doomed.isEmpty else { return }
        totalFreed = doomed.reduce(0) { $0 + $1.size }
        phase = .done
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            for item in doomed {
                do { try fm.trashItem(at: item.url, resultingItemURL: nil) }
                catch { try? fm.removeItem(at: item.url) }
            }
        }
    }

    // MARK: Auto-Clean

    private func checkAutoClean() {
        guard autoCleanEnabled else { return }
        let cal = Calendar.current, now = Date()
        let weekday = cal.component(.weekday, from: now)   // 1=Sunday
        let hour = cal.component(.hour, from: now)
        guard weekday == autoCleanDay && hour == autoCleanHour else { return }
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
            do {
                try fm.trashItem(at: item.url, resultingItemURL: nil)
                freed += item.size
            } catch {
                do { try fm.removeItem(at: item.url); freed += item.size }
                catch {}
            }
        }
        if freed > 0 { sendNotification(freed: freed) }
    }

    private func sendNotification(freed: Int64) {
        let content = UNMutableNotificationContent()
        content.title = "Clear Attic"
        content.body = "Attic cleared. \(formatBytes(freed)) freed."
        content.sound = .default
        let req = UNNotificationRequest(identifier: "auto-clean-\(Date())", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: Scan logic (shared between interactive & auto-clean)

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
        pop.contentSize = NSSize(width: 320, height: 232)
        pop.behavior = .transient
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

    private var height: CGFloat {
        switch vm.phase {
        case .idle:     return vm.autoCleanEnabled ? 264 : 232
        case .scanning: return 200
        case .results:
            if vm.items.isEmpty { return 180 }
            let rows = min(vm.items.count, 7)
            return min(CGFloat(40 + rows * 40 + 78), 400)
        case .done:     return 240
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            switch vm.phase {
            case .idle:     IdleView(vm: vm)
            case .scanning: ScanningView(vm: vm)
            case .results:  ResultsView(vm: vm)
            case .done:     DoneView(vm: vm)
            }
        }
        .frame(width: 320, height: height)
        .animation(.easeInOut(duration: 0.2), value: vm.phase)
        .animation(.easeInOut(duration: 0.15), value: vm.autoCleanEnabled)
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

struct HeaderBar: View {
    var isDemo = false
    var onScanAgain: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "archivebox.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.primary)
                Text("Clear Attic")
                    .font(.system(size: 15, weight: .semibold))
                if isDemo {
                    Text("Demo")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .foregroundColor(.secondary)
                        .cornerRadius(4)
                }
                Spacer()
                if let action = onScanAgain {
                    Button(action: action) {
                        HStack(spacing: 3) {
                            Text("↩")
                            Text("⌘S").font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                        }.font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.primary)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
            Divider()
        }
    }
}

struct MenuRow: View {
    let title: String
    let shortcut: String
    var isSecondary = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 14))
                    .foregroundColor(isSecondary ? .secondary : .primary)
                Spacer()
                Text(shortcut).font(.system(size: 12, design: .monospaced)).foregroundColor(.secondary)
            }
            .padding(.horizontal, 16).frame(height: 40)
            .background(hovered ? Color.primary.opacity(0.06) : .clear)
            .cornerRadius(6).contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovered = $0 }.padding(.horizontal, 4)
    }
}

struct ToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    var detail: String? = nil

    var body: some View {
        HStack {
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch).controlSize(.mini)
            if let detail {
                Spacer()
                Text(detail).font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
        .font(.system(size: 12)).foregroundColor(.secondary)
        .padding(.horizontal, 20).frame(height: 32)
    }
}

struct Badge: View {
    let category: ItemCategory
    var body: some View {
        Text(category.rawValue)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Color.secondary.opacity(0.12))
            .foregroundColor(.secondary)
            .cornerRadius(4)
    }
}

// MARK: - Idle

struct IdleView: View {
    @ObservedObject var vm: AtticVM
    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(isDemo: vm.demoMode)
            Spacer().frame(height: 6)
            MenuRow(title: "Scan Attic", shortcut: "⌘S") { vm.scan() }
            Divider().padding(.horizontal, 16)

            ToggleRow(title: "Launch at Login", isOn: $vm.launchAtLogin)
            ToggleRow(title: "Auto-Clean", isOn: $vm.autoCleanEnabled,
                      detail: vm.autoCleanEnabled ? vm.scheduleText : nil)

            if vm.autoCleanEnabled {
                HStack(spacing: 8) {
                    Picker("", selection: $vm.autoCleanDay) {
                        ForEach(1...7, id: \.self) { Text(AtticVM.days[$0 - 1]).tag($0) }
                    }.labelsHidden()
                    Picker("", selection: $vm.autoCleanHour) {
                        ForEach(0..<24, id: \.self) { Text(AtticVM.hourLabel($0)).tag($0) }
                    }.labelsHidden()
                }
                .controlSize(.small)
                .padding(.horizontal, 24).frame(height: 28)
            }

            Divider().padding(.horizontal, 16)
            ToggleRow(title: "Demo Mode", isOn: $vm.demoMode)
            Divider().padding(.horizontal, 16)
            MenuRow(title: "Quit", shortcut: "⌘Q", isSecondary: true) { NSApp.terminate(nil) }
            Spacer().frame(height: 6)
        }
    }
}

// MARK: - Scanning

struct ScanningView: View {
    @ObservedObject var vm: AtticVM
    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(isDemo: vm.demoMode)
            Spacer()
            VStack(spacing: 14) {
                ProgressView().scaleEffect(1.3)
                Text("Poking around the attic…").font(.system(size: 14))
                Text("\(vm.scannedCount.formatted()) items checked")
                    .font(.system(size: 12)).foregroundColor(.secondary).monospacedDigit()
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
            HeaderBar(isDemo: vm.demoMode, onScanAgain: vm.scan)

            if vm.items.isEmpty {
                Spacer()
                Text("Nothing dusty up here. You're good.")
                    .font(.system(size: 14)).foregroundColor(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(vm.items) { item in
                            ResultRow(item: item) { vm.toggle(item.id) }
                            Divider().padding(.leading, 16)
                        }
                    }
                }
                Divider()

                HStack(spacing: 0) {
                    Button("All") { vm.selectAll() }.keyboardShortcut("a", modifiers: .command)
                    Text("  ⌘A").font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                    Spacer().frame(width: 16)
                    Button("None") { vm.selectNone() }
                    Spacer()
                    Text("\(vm.selectedCount) items").foregroundColor(.secondary)
                }
                .font(.system(size: 12)).buttonStyle(.plain).foregroundColor(.primary)
                .padding(.horizontal, 16).frame(height: 32)

                Divider()

                HStack {
                    Spacer()
                    Button {
                        vm.clear()
                    } label: {
                        HStack(spacing: 5) {
                            Text("Clear Selected").fontWeight(.semibold)
                            Text("⌘⌫").font(.system(size: 11, design: .monospaced)).opacity(0.7)
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        }
                        .font(.system(size: 13))
                        .foregroundColor(vm.selectedCount > 0 ? .red : .secondary)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(vm.selectedCount == 0)
                }
                .padding(.horizontal, 16).frame(height: 36)
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
                    .foregroundColor(item.isSelected ? .primary : .secondary)
                    .font(.system(size: 14))
                Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 4)
                Badge(category: item.category)
                Text(formatBytes(item.size))
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .frame(minWidth: 55, alignment: .trailing)
            }
            .padding(.horizontal, 16).frame(height: 40)
            .background(hovered ? Color.primary.opacity(0.06) :
                            item.isSelected ? Color.primary.opacity(0.04) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovered = $0 }
    }
}

// MARK: - Done

struct DoneView: View {
    @ObservedObject var vm: AtticVM

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(isDemo: vm.demoMode)
            Spacer()
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.green)
                Text("Attic cleared.\nFeels lighter, doesn't it?")
                    .font(.system(size: 14)).foregroundColor(.secondary).multilineTextAlignment(.center)
                Text(formatBytes(vm.totalFreed))
                    .font(.system(size: 28, weight: .bold))
                Text("freed").font(.system(size: 13)).foregroundColor(.secondary)
            }
            Spacer()
            Divider().padding(.horizontal, 16)
            MenuRow(title: "Scan Again", shortcut: "⌘S") { vm.scan() }
            Spacer().frame(height: 4)
        }
    }
}
