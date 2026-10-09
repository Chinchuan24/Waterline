import AppKit
import WaterlineCore
import ServiceManagement
import SwiftUI

enum PanelTab: String, CaseIterable, Identifiable {
  case apps, history, localAI

  var id: Self { self }

  var title: String {
    switch self {
    case .apps: "Apps"
    case .history: "History"
    case .localAI: "Local AI"
    }
  }
}

/// The popover shown when the menu bar item is clicked.
struct MemoryPanel: View {
  let monitor: MemoryMonitor

  /// 320 pt for the list, less on short screens (e.g. a 13" MacBook Air at "Larger Text")
  /// so the whole panel still fits below the menu bar.
  static var tabHeight: CGFloat {
    let screen = NSScreen.main?.visibleFrame.height ?? 900
    return min(320, max(180, screen - 420))
  }
  @AppStorage(Settings.panelTab) private var tab: PanelTab = .apps

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 12) {
        VerdictCard(verdict: monitor.panel.verdict)
        SummaryHeader(memory: monitor.panel.system)
        CompositionBar(memory: monitor.panel.system)
        CompositionLegend(memory: monitor.panel.system)
        Picker("View", selection: $tab) {
          ForEach(PanelTab.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: .infinity)
      }
      .padding([.horizontal, .top], 16)
      .padding(.bottom, 10)

      Group {
        switch tab {
        case .apps: AppsTab(monitor: monitor)
        case .history: HistoryTab(monitor: monitor)
        case .localAI: LocalAITab(monitor: monitor)
        }
      }
      .frame(height: Self.tabHeight)

      Divider()
      PanelFooter(unreadableCount: monitor.panel.processes.unreadableCount)
    }
    .frame(width: 380)
    .background(WindowVisibilityObserver { monitor.setPanelVisible($0) })
  }
}

// MARK: - Verdict

private struct VerdictCard: View {
  let verdict: MemoryVerdict

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: verdict.level.symbol)
        .font(.title2)
        .foregroundStyle(verdict.level.color)
      VStack(alignment: .leading, spacing: 2) {
        Text(verdict.headline).font(.headline)
        Text(verdict.detail)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(12)
    .background(verdict.level.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .animation(.smooth, value: verdict)
  }
}

// MARK: - Summary

private struct SummaryHeader: View {
  let memory: SystemMemory

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text(Bytes.format(memory.used, gbDecimals: 2))
        .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
        .contentTransition(.numericText())
        .animation(.snappy, value: memory.used)
        .fixedSize()
      Text("of \(Bytes.format(memory.total, gbDecimals: 0)) · \(Int((memory.usedFraction * 100).rounded()))%")
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .lineLimit(1)
      Spacer(minLength: 4)
      PressureBadge(pressure: memory.pressure, percent: memory.pressurePercent)
    }
  }
}

private struct PressureBadge: View {
  let pressure: MemoryPressure
  let percent: Int

  var body: some View {
    HStack(spacing: 5) {
      Circle().fill(pressure.color).frame(width: 7, height: 7)
      Text("Pressure \(percent)%").monospacedDigit()
    }
    .font(.caption.weight(.medium))
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(pressure.color.opacity(0.14), in: Capsule())
    .help("Memory pressure: \(pressure.label). How hard macOS is working to find free memory. Yellow or red means apps may slow down.")
  }
}

// MARK: - Composition

private enum Segment: CaseIterable {
  case app, wired, compressed, cached

  var title: String {
    switch self {
    case .app: "App"
    case .wired: "Wired"
    case .compressed: "Compressed"
    case .cached: "Cached Files"
    }
  }

  var color: Color {
    switch self {
    case .app: .blue
    case .wired: .orange
    case .compressed: .purple
    case .cached: .gray.opacity(0.55)
    }
  }

  var explanation: String {
    switch self {
    case .app: "Memory used by apps and their processes."
    case .wired: "Memory the system needs that can't be compressed or paged out. GPU memory for local AI models shows up here."
    case .compressed: "Memory compressed to make room for more. Counts as used."
    case .cached: "Recently used files kept in RAM. Freed instantly when apps need it, so it's not counted as used."
    }
  }

  func bytes(in memory: SystemMemory) -> UInt64 {
    switch self {
    case .app: memory.app
    case .wired: memory.wired
    case .compressed: memory.compressed
    case .cached: memory.cached
    }
  }
}

private struct CompositionBar: View {
  let memory: SystemMemory

  var body: some View {
    GeometryReader { proxy in
      HStack(spacing: 1.5) {
        ForEach(Segment.allCases, id: \.self) { segment in
          let fraction = memory.total == 0 ? 0 : Double(segment.bytes(in: memory)) / Double(memory.total)
          Rectangle()
            .fill(segment.color)
            .frame(width: max(0, proxy.size.width * fraction - 1.5))
        }
        Spacer(minLength: 0)
      }
      .background(.quaternary)
      .clipShape(RoundedRectangle(cornerRadius: 4))
      .animation(.smooth(duration: 0.6), value: memory)
    }
    .frame(height: 10)
  }
}

private struct CompositionLegend: View {
  let memory: SystemMemory

  var body: some View {
    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
      GridRow {
        entry(.app)
        entry(.wired)
      }
      GridRow {
        entry(.compressed)
        entry(.cached)
      }
      GridRow {
        row(swatch: AnyView(Image(systemName: "arrow.left.arrow.right").font(.system(size: 8, weight: .bold))),
            title: "Swap", value: memory.swapUsed)
          .help("Memory written to the SSD because RAM ran short. A growing number means you're running out.")
        row(swatch: AnyView(RoundedRectangle(cornerRadius: 2).strokeBorder(.secondary, lineWidth: 1)),
            title: "Free", value: memory.free)
      }
    }
    .font(.callout)
  }

  private func entry(_ segment: Segment) -> some View {
    row(swatch: AnyView(RoundedRectangle(cornerRadius: 2).fill(segment.color)),
        title: segment.title, value: segment.bytes(in: memory))
      .help(segment.explanation)
  }

  private func row(swatch: AnyView, title: String, value: UInt64) -> some View {
    HStack(spacing: 6) {
      swatch.frame(width: 9, height: 9).foregroundStyle(.secondary)
      Text(title).foregroundStyle(.secondary)
      Spacer(minLength: 4)
      Text(Bytes.format(value, gbDecimals: 2)).monospacedDigit()
    }
  }
}

// MARK: - Footer

private struct PanelFooter: View {
  let unreadableCount: Int
  @AppStorage(Settings.menuBarStyle) private var style: MenuBarStyle = .percent
  @AppStorage(Settings.floatingMeter) private var floatingMeter = false
  @AppStorage(Settings.notifications) private var notifications = true
  @State private var loginStatus: SMAppService.Status = .notRegistered
  @State private var loginError: String?

  private func refreshLoginStatus() {
    loginStatus = SMAppService.mainApp.status
  }

  private func setLaunchAtLogin(_ enabled: Bool) {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      loginError = nil
    } catch {
      loginError = "Could not change automatic startup. Run Waterline from Applications and try again. \(error.localizedDescription)"
    }
    refreshLoginStatus()
  }

  var body: some View {
    HStack {
      Menu {
        Picker("Show in Menu Bar", selection: $style) {
          ForEach(MenuBarStyle.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.inline)
        Divider()
        Toggle("Floating Meter", isOn: $floatingMeter)
        Toggle("Notifications", isOn: $notifications)
          .disabled(!Notifier.isSupported)
        Toggle("Start Automatically at Login", isOn: Binding(
          get: { loginStatus == .enabled },
          set: { setLaunchAtLogin($0) }
        ))
        .help("Open Waterline automatically after you sign in to your Mac.")
        if loginStatus == .requiresApproval {
          Button("Approve Startup in System Settings…") {
            SMAppService.openSystemSettingsLoginItems()
          }
          Button("Cancel Startup Request") { setLaunchAtLogin(false) }
        }
        if let loginError {
          Text(loginError)
        }
        Button("Login Items Settings…") {
          SMAppService.openSystemSettingsLoginItems()
        }
        .onAppear { refreshLoginStatus() }
      } label: {
        Image(systemName: "gearshape")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Settings")

      if unreadableCount > 0 {
        Text("+\(unreadableCount) system processes")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .help("macOS only lets an app measure processes you own. System processes like the kernel and WindowServer aren't listed, but they're counted in Memory Used.")
      }

      Spacer()

      Button("Activity Monitor") { ActivityMonitor.open() }
      Button("Quit") { NSApplication.shared.terminate(nil) }
        .keyboardShortcut("q")
    }
    .controlSize(.small)
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .onChange(of: floatingMeter) { _, visible in
      FloatingMeter.shared.setVisible(visible)
    }
    .onChange(of: notifications) { _, enabled in
      if enabled { Notifier.requestAuthorization() }
    }
    .onAppear { refreshLoginStatus() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      refreshLoginStatus()
    }

  }
}
