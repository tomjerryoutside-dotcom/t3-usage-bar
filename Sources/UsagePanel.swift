import AppKit
import SwiftUI

@MainActor
final class UsageState: ObservableObject {
    @Published var period: Period = .today
    @Published private(set) var report: Report?
    @Published private(set) var error: String?
    @Published private(set) var refreshing = false
    @Published private(set) var antigravityQuota: QuotaSnapshot?
    @Published private(set) var quotaError = false
    private var refreshingQuota = false

    func refresh() {
        refreshAntigravityQuota()
        guard !refreshing else { return }
        refreshing = true
        Task {
            do {
                report = try await Task.detached(priority: .utility) { try Report.read() }.value
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            refreshing = false
        }
    }

    private func refreshAntigravityQuota() {
        guard !refreshingQuota else { return }
        refreshingQuota = true
        Task {
            do {
                antigravityQuota = try await AntigravityQuota.read()
                quotaError = false
            } catch {
                antigravityQuota = nil
                quotaError = true
            }
            refreshingQuota = false
        }
    }
}

struct UsagePanel: View {
    @ObservedObject var state: UsageState
    private let cardBackground = Color(nsColor: .controlBackgroundColor)
    private let border = Color(nsColor: .separatorColor)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let report = state.report {
                VStack(alignment: .leading, spacing: 8) {
                    card("订阅额度", icon: "gauge.with.dots.needle.33percent") {
                        TimelineView(.everyMinute) { clock in
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Provider.allCases) { provider in
                                    if provider != .codex { Divider() }
                                    quota(provider, report: report, now: clock.date)
                                }
                            }
                        }
                    }
                    card("用量与缓存", icon: "chart.bar.xaxis") {
                        HStack(alignment: .top, spacing: 10) {
                            usage(.codex, report: report)
                            Divider()
                            usage(.antigravity, report: report)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    card("模型明细", icon: "list.bullet") {
                        models(report)
                    }
                }
                .padding(10)
                Spacer(minLength: 0)
            } else {
                Spacer()
                if state.refreshing { ProgressView().controlSize(.small) }
                Spacer()
            }
            if let error = state.error {
                Text(error).font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            Divider()
            HStack {
                Button("打开 T3 Code", action: openT3)
                Spacer()
                if let time = state.report?.readAt {
                    Text("更新于 \(time.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Button("退出") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 15)
            .padding(.vertical, 9)
        }
        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(border.opacity(0.55)).allowsHitTesting(false) }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Picker("时间范围", selection: $state.period) {
                ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Button(action: state.refresh) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .accessibilityLabel("刷新用量")
                .help("刷新用量与额度")
                .disabled(state.refreshing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func card<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
            Divider()
            content()
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(border.opacity(0.55)).allowsHitTesting(false) }
    }

    private func heading(_ provider: Provider) -> some View {
        HStack(spacing: 6) {
            Circle().fill(provider.accent).frame(width: 6, height: 6).accessibilityHidden(true)
            Text(provider.name).font(.caption.weight(.semibold))
        }
    }

    private func quota(_ provider: Provider, report: Report, now: Date) -> some View {
        let failed = provider == .antigravity && state.quotaError
        let live = provider == .antigravity ? state.antigravityQuota : nil
        let snapshot = failed ? nil : live ?? report.quota(for: provider)
        let windows = snapshot?.windows ?? []
        let source = snapshot?.source ?? (provider == .codex && !windows.isEmpty ? "自动同步" : nil)
        let plan = provider == .codex ? report.catalogs[provider]?.chatGPTPlan : snapshot?.plan
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                heading(provider)
                if let plan {
                    Text(plan).font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary).lineLimit(1)
                        .help(provider == .codex ? "T3 回报的 ChatGPT 订阅" : "Google One 核对的当前账号方案")
                }
                Spacer()
                if let source {
                    let stamp = parsedDate(snapshot?.checkedAt).map {
                        " · " + $0.formatted(.dateTime.month().day().hour().minute())
                    } ?? ""
                    Text(source + stamp)
                        .font(.caption2).foregroundStyle(.secondary)
                } else if windows.isEmpty {
                    Text(failed ? "额度源暂不可用" : "额度与重置暂无")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !windows.isEmpty {
                ForEach(windows) { window in
                    let reset = parsedDate(window.resetsAt)
                    let pending = reset.map { $0 <= now } ?? false
                    let remaining = pending ? nil : window.usedPercent.map { max(0, min(1, 1 - $0 / 100)) }
                    HStack(spacing: 6) {
                        Text(window.title).lineLimit(1)
                            .frame(width: 124, alignment: .leading)
                        GeometryReader { track in
                            if let remaining {
                                Capsule()
                                    .fill(.secondary.opacity(0.18))
                                    .overlay(alignment: .leading) {
                                        Capsule()
                                            .fill(provider.accent)
                                            .frame(width: track.size.width * remaining)
                                    }
                            }
                        }
                        .frame(height: 6)
                        .accessibilityHidden(true)
                        Group {
                            if let remaining {
                                Text(percentText(remaining) + " 剩余").foregroundStyle(provider.accent)
                            } else {
                                Text(pending ? "待刷新" : "剩余未知").foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 74, alignment: .trailing)
                        Group {
                            if let reset {
                                Text(resetCountdown(until: reset, from: now, approximate: window.approximateReset == true))
                            } else {
                                Text("未显示重置时间")
                            }
                        }
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(width: 100, alignment: .trailing)
                    }
                    .font(.caption.monospacedDigit())
                }
            }
        }
    }

    private func resetCountdown(until reset: Date, from now: Date, approximate: Bool) -> String {
        guard reset > now else { return "重置时间已到" }
        let totalMinutes = Int(ceil(reset.timeIntervalSince(now) / 60))
        let days = totalMinutes / (24 * 60)
        let hours = totalMinutes / 60 % 24
        let minutes = totalMinutes % 60
        let prefix = approximate ? "约 " : ""
        if days > 0 { return "\(prefix)\(days)天 \(hours)小时 \(minutes)分后" }
        if hours > 0 { return "\(prefix)\(hours)小时 \(minutes)分后" }
        return "\(prefix)\(minutes)分后"
    }

    private func usage(_ provider: Provider, report: Report) -> some View {
        let summary = report.summary(state.period, provider: provider)
        let total = summary.tokens
        let known = total.measuredInput == total.input && total.turns > 0
        return VStack(alignment: .leading, spacing: 6) {
            heading(provider)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(compact(total.total)).font(.system(size: 21, weight: .semibold, design: .rounded))
                    .monospacedDigit().accessibilityLabel("\(total.total.formatted()) Tokens")
                Text("Tokens").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                metric("未缓存", known ? compact(total.input - total.cached) : "—")
                metric("缓存输入", known ? compact(total.cached) : "—")
                metric("输出", compact(total.output))
            }
            Text(total.hitRate.map { "缓存命中 " + percentText($0) } ?? "缓存命中 —")
                .font(.caption.weight(.medium)).foregroundStyle(provider.accent)
            if state.period != .today && total.turns > 0 {
                trend(summary.daily, accent: provider.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func trend(_ counts: [Int64], accent: Color) -> some View {
        let maxCount = Double(max(counts.max() ?? 0, 1))
        return HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(counts.enumerated()), id: \.offset) { _, count in
                RoundedRectangle(cornerRadius: 2).fill(count == 0 ? Color.secondary.opacity(0.17) : accent.opacity(0.65))
                    .frame(height: max(2, 22 * Double(count) / maxCount))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 22, alignment: .bottom)
        .accessibilityLabel("每日 Token 用量，从左到右按日期")
    }

    private func models(_ report: Report) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("模型")
                Spacer()
                Text("Tokens").frame(width: 70, alignment: .trailing)
                Text("缓存命中").frame(width: 64, alignment: .trailing)
            }
            .font(.caption2).foregroundStyle(.secondary)
            ForEach(Provider.allCases) { provider in
                if provider != .codex { Divider() }
                ForEach(report.summary(state.period, provider: provider).models) { model in
                    HStack(spacing: 6) {
                        Circle().fill(provider.accent).frame(width: 5, height: 5).accessibilityHidden(true)
                        Text(model.name).lineLimit(1).help(model.name)
                        Spacer(minLength: 0)
                        Text(model.tokens.turns > 0 ? compact(model.tokens.total) : "未使用")
                            .foregroundStyle(model.tokens.turns > 0 ? Color.primary : Color.secondary)
                            .frame(width: 70, alignment: .trailing)
                        Text(model.tokens.hitRate.map(percentText) ?? "—")
                            .foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
                    }
                    .font(.caption.monospacedDigit())
                }
            }
        }
    }

    private func percentText(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(1)))
    }

    private func openT3() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.t3tools.t3code") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

private final class DropdownPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class MenuBarApp: NSObject, NSApplicationDelegate {
    private let state = UsageState()
    private var item: NSStatusItem?
    private var panel: DropdownPanel?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.item = item
        item.button?.image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: "T3 用量")
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "T3 用量"
        item.button?.setAccessibilityLabel("T3 用量")
        item.button?.target = self
        item.button?.action = #selector(togglePanel)

        state.refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.state.refresh() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self, let panel = self.panel, panel.isVisible else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                panel.orderOut(nil)
                return nil
            }
            if event.type != .keyDown, event.window != panel, event.window != self.item?.button?.window {
                panel.orderOut(nil)
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.panel?.orderOut(nil) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    }

    @objc private func togglePanel() {
        if let panel, panel.isVisible { panel.orderOut(nil) }
        else { showPanel() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showPanel()
        return false
    }

    private func showPanel() {
        guard let button = item?.button, let window = button.window,
              let screen = window.screen else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = screen.visibleFrame
        let top = min(visible.maxY, anchor.minY) - 5
        let width = min(438, visible.width - 16)
        let height = min(550, top - visible.minY - 8)
        guard width > 0, height > 0 else { return }
        let left = min(max(anchor.midX - width / 2, visible.minX + 8), visible.maxX - width - 8)
        let frame = NSRect(x: left, y: top - height, width: width, height: height)

        let panel: DropdownPanel
        if let existing = self.panel {
            panel = existing
        } else {
            panel = DropdownPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "T3 用量"
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.level = .popUpMenu
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: UsagePanel(state: state))
            self.panel = panel
        }
        panel.setFrame(frame, display: true)
        state.refresh()
        panel.makeKeyAndOrderFront(nil)
    }
}
