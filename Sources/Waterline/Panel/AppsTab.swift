import AppKit
import WaterlineCore
import SwiftUI

/// An action that needs a second click, shown inline above the list. Inline rather than
/// an alert, because a modal would close the menu bar panel out from under you.
private struct PendingAction: Identifiable {
  let id = UUID()
  let message: String
  let confirmTitle: String
  let perform: () -> Void
}

struct AppsTab: View {
  let monitor: MemoryMonitor
  @State private var expanded: Set<String> = []
  @State private var showAll = false
  @State private var pending: PendingAction?
  @State private var review: [ProcessControl.ReviewCandidate]?
  @State private var selected: Set<String> = []
  @State private var quitFeedback: String?

  private static let collapsedCount = 15

  private var snapshot: ProcessSnapshot { monitor.panel.processes }

  var body: some View {
    VStack(spacing: 0) {
      header
      if let pending {
        ConfirmBar(action: pending) { self.pending = nil }
          .transition(.move(edge: .top).combined(with: .opacity))
      }
      if let review {
        reviewList(review)
      } else if snapshot.groups.isEmpty {
        ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        list
      }
    }
    .animation(.snappy(duration: 0.25), value: pending?.id)
    // A confirmation must not outlive the panel: reopening later and pressing Return
    // shouldn't act on a list the user is no longer looking at.
    .onChange(of: monitor.isPanelVisible) { _, visible in
      if !visible { pending = nil }
    }
  }

  private var header: some View {
    HStack {
      Text("Using the most memory").font(.subheadline.weight(.semibold))
      Spacer()
      Button("Close Unused…") {
        pending = nil
        quitFeedback = nil
        selected = []
        review = ProcessControl.reviewCandidates(in: snapshot)
      }
      .buttonStyle(.borderless)
      .font(.callout)
      .help("Review background apps and choose which ones you no longer need.")
    }
    .padding(.horizontal, 16)
    .padding(.bottom, 4)
  }

  private func reviewList(_ candidates: [ProcessControl.ReviewCandidate]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Choose apps you no longer need. Background apps may still be playing audio or doing work.")
        .font(.caption).foregroundStyle(.secondary)
      ScrollView {
        VStack(spacing: 8) {
          if candidates.isEmpty {
            Text("No background apps available to close.").font(.callout)
          }
          ForEach(candidates) { candidate in
            Toggle(isOn: Binding(
              get: { selected.contains(candidate.id) },
              set: { if $0 { selected.insert(candidate.id) } else { selected.remove(candidate.id) } }
            )) {
              HStack {
                Text(candidate.group.name).lineLimit(1)
                Spacer()
                Text(Bytes.format(candidate.group.footprint)).monospacedDigit().foregroundStyle(.secondary)
              }
            }
            .toggleStyle(.checkbox)
          }
        }
      }
      if let quitFeedback {
        Text(quitFeedback).font(.caption).foregroundStyle(.secondary)
      } else {
        let total = candidates.filter { selected.contains($0.id) }.reduce(UInt64(0)) { $0 + $1.group.footprint }
        Text("Selected apps use about \(Bytes.format(total)). Actual memory freed may vary.")
          .font(.caption).foregroundStyle(.secondary)
      }
      HStack {
        Button("Back") { review = nil; selected = [] }
        Spacer()
        Button("Quit Selected (\(selected.count))") {
          let count = ProcessControl.quitReviewed(candidates.filter { selected.contains($0.id) })
          selected = []
          quitFeedback = "Sent \(count) quit requests. Check apps for save prompts; exited or active apps are skipped."
          review = ProcessControl.reviewCandidates(in: monitor.panel.processes)
          monitor.rescanSoon()
        }
        .disabled(selected.isEmpty)
      }
      .controlSize(.small)
    }
    .padding(.horizontal, 16)
    .padding(.bottom, 8)
  }

  private var list: some View {
    ScrollView {
      LazyVStack(spacing: 6) {
        ForEach(monitor.panel.suspects, id: \.appID) { suspect in
          LeakCallout(report: suspect)
        }
        if !snapshot.electronApps.isEmpty {
          ElectronCallout(apps: snapshot.electronApps)
        }

        VStack(spacing: 0) {
          let shown = showAll ? snapshot.groups[...] : snapshot.groups.prefix(Self.collapsedCount)
          let largest = snapshot.groups.first?.footprint ?? 1
          ForEach(shown) { group in
            AppRow(
              group: group,
              largest: largest,
              growth: monitor.panel.growth[group.id],
              trend: monitor.panel.trends[group.id] ?? [],
              isExpanded: expanded.contains(group.id),
              toggle: { toggle(group.id) },
              close: { close(group) },
              forceClose: { confirmForceClose(group) },
              endProcess: { confirmEnd($0, force: $1) })
          }
          if snapshot.groups.count > Self.collapsedCount {
            Button(showAll ? "Show Fewer" : "Show All \(snapshot.groups.count)") { showAll.toggle() }
              .buttonStyle(.link)
              .font(.callout)
              .padding(.vertical, 8)
          }
        }
      }
      .padding(.horizontal, 8)
      .padding(.bottom, 8)
    }
  }

  // MARK: Actions

  private func toggle(_ id: String) {
    withAnimation(.snappy(duration: 0.25)) {
      if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
  }

  /// Quitting an app is safe (it can ask to save), so it happens on the first click.
  /// Ending a standalone tool's processes is not (a dev server, a CLI session), so ask first.
  private func close(_ group: AppGroup) {
    guard group.bundlePath == nil else {
      ProcessControl.close(group)
      monitor.rescanSoon()
      return
    }
    let count = group.processes.count
    pending = PendingAction(
      message: "End \(count == 1 ? "the" : "all \(count)") \(group.name) \(count == 1 ? "process" : "processes")? Anything running in \(count == 1 ? "it" : "them") stops without saving.",
      confirmTitle: "End"
    ) {
      ProcessControl.close(group)
      monitor.rescanSoon()
    }
  }

  private func confirmForceClose(_ group: AppGroup) {
    pending = PendingAction(
      message: "Force quit \(group.name)? Unsaved changes will be lost.",
      confirmTitle: "Force Quit"
    ) {
      ProcessControl.close(group, force: true)
      monitor.rescanSoon()
    }
  }

  private func confirmEnd(_ process: ProcessSample, force: Bool) {
    pending = PendingAction(
      message: force
        ? "Force end \(process.name) (\(process.pid))? Unsaved changes will be lost."
        : "End \(process.name) (\(process.pid))? Its app may reload it or show an error.",
      confirmTitle: force ? "Force End" : "End Process"
    ) {
      ProcessControl.end(process, force: force)
      monitor.rescanSoon()
    }
  }
}

private struct ConfirmBar: View {
  let action: PendingAction
  let dismiss: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(action.message)
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        Button("Cancel", action: dismiss)
          .keyboardShortcut(.cancelAction)
        Button(action.confirmTitle, role: .destructive) {
          action.perform()
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
      }
      .controlSize(.small)
    }
    .padding(10)
    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .padding(.horizontal, 12)
    .padding(.bottom, 6)
  }
}

// MARK: - Callouts

private struct LeakCallout: View {
  let report: GrowthReport

  var body: some View {
    Callout(
      symbol: "chart.line.uptrend.xyaxis", tint: .orange,
      title: "\(report.name) keeps growing",
      message: "+\(Bytes.format(UInt64(max(0, report.growth)))) in \(Int(report.duration / 60)) min without giving any back. Restarting it usually frees this memory.")
  }
}

private struct ElectronCallout: View {
  let apps: [AppGroup]

  var body: some View {
    let total = apps.reduce(0) { $0 + $1.footprint }
    Callout(
      symbol: "atom", tint: .indigo,
      title: "\(apps.count) Electron \(apps.count == 1 ? "app is" : "apps are") using \(Bytes.format(total))",
      message: apps.prefix(4).map(\.name).joined(separator: ", ") + (apps.count > 4 ? "…" : ""))
    .help("Electron apps each bundle their own copy of the Chromium browser, which is why they tend to use more memory than native Mac apps.")
  }
}

private struct Callout: View {
  let symbol: String
  let tint: Color
  let title: String
  let message: String

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: symbol).foregroundStyle(tint).frame(width: 18)
      VStack(alignment: .leading, spacing: 1) {
        Text(title).font(.callout.weight(.semibold))
        Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(8)
    .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

// MARK: - Rows

private struct AppRow: View {
  let group: AppGroup
  let largest: UInt64
  let growth: GrowthReport?
  let trend: [UInt64]
  let isExpanded: Bool
  let toggle: () -> Void
  let close: () -> Void
  let forceClose: () -> Void
  let endProcess: (ProcessSample, Bool) -> Void
  @State private var isHovered = false

  private var canExpand: Bool { group.processes.count > 1 }
  private var canClose: Bool { ProcessControl.canClose(group) }
  private var isSuspect: Bool { growth?.isSuspect ?? false }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: "chevron.right")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(.tertiary)
          .rotationEffect(.degrees(isExpanded ? 90 : 0))
          .opacity(canExpand ? 1 : 0)
          .frame(width: 10)

        AppIcon(bundlePath: group.bundlePath)

        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 4) {
            Text(group.name).lineLimit(1).truncationMode(.tail)
            if canExpand { Badge(text: "\(group.processes.count)", tint: .secondary) }
            if group.isElectron { Badge(text: "Electron", tint: .indigo) }
          }
          ShareBar(fraction: Double(group.footprint) / Double(max(largest, 1)))
        }

        Spacer(minLength: 6)

        if trend.count >= 4 {
          Sparkline(values: trend.map(Double.init))
            .stroke(isSuspect ? Color.orange : Color.secondary.opacity(0.6), lineWidth: 1.2)
            .frame(width: 34, height: 14)
            .help(isSuspect ? "Growing steadily — possible memory leak" : "Memory over the last hour")
        }

        Text(Bytes.format(group.footprint, gbDecimals: 2))
          .monospacedDigit()
          .foregroundStyle(isSuspect ? .orange : .primary)
          .frame(minWidth: 62, alignment: .trailing)

        CloseButton(enabled: canClose, visible: isHovered, action: close)
          .help(group.bundlePath == nil ? "End \(group.name)" : "Quit \(group.name)")
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .contentShape(Rectangle())
      .background(isHovered ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
      .onTapGesture { if canExpand { toggle() } }
      .onHover { isHovered = $0 }
      .contextMenu { menu }
      // The ✕ only appears on hover, so give keyboard and VoiceOver users the same actions.
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(.isButton)
      .accessibilityActions {
        if canExpand {
          Button(isExpanded ? "Hide processes" : "Show processes", action: toggle)
        }
        if canClose {
          Button(group.bundlePath == nil ? "End \(group.name)" : "Quit \(group.name)", action: close)
        }
      }

      if isExpanded && canExpand {
        VStack(spacing: 0) {
          ForEach(group.processes) { process in
            ProcessRow(process: process, end: endProcess)
          }
        }
        .padding(.bottom, 4)
        .transition(.opacity)
      }
    }
  }

  @ViewBuilder private var menu: some View {
    if canClose {
      Button(group.bundlePath == nil ? "End \(group.name)" : "Quit \(group.name)", action: close)
      Button("Force Quit \(group.name)…", action: forceClose)
      Divider()
    }
    if let bundlePath = group.bundlePath {
      Button("Show in Finder") {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: bundlePath)])
      }
    }
    Button("Open Activity Monitor") { ActivityMonitor.open() }
  }
}

private struct ProcessRow: View {
  let process: ProcessSample
  let end: (ProcessSample, Bool) -> Void
  @State private var isHovered = false

  var body: some View {
    HStack {
      Text(process.name).lineLimit(1).truncationMode(.middle)
      Text("\(process.pid)").foregroundStyle(.tertiary).monospacedDigit()
      Spacer(minLength: 8)
      Text(Bytes.format(process.footprint, gbDecimals: 2)).monospacedDigit()
      CloseButton(enabled: ProcessControl.canEnd(process), visible: isHovered) { end(process, false) }
        .help("End this process")
    }
    .font(.callout)
    .foregroundStyle(.secondary)
    .padding(.leading, 56)
    .padding(.trailing, 8)
    .padding(.vertical, 2)
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
    .accessibilityElement(children: .combine)
    .accessibilityActions {
      if ProcessControl.canEnd(process) {
        Button("End process") { end(process, false) }
      }
    }
    .contextMenu {
      if ProcessControl.canEnd(process) {
        Button("End Process…") { end(process, false) }
        Button("Force End Process…") { end(process, true) }
      }
    }
  }
}

/// A quiet ✕ that appears on hover, like closing a tab.
private struct CloseButton: View {
  let enabled: Bool
  let visible: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: "xmark.circle.fill")
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .symbolRenderingMode(.hierarchical)
    }
    .buttonStyle(.plain)
    .frame(width: 16)
    .opacity(enabled && visible ? 1 : 0)
    .disabled(!enabled || !visible)
  }
}

private struct Badge: View {
  let text: String
  let tint: Color

  var body: some View {
    Text(text)
      .font(.caption2.weight(.medium).monospacedDigit())
      .foregroundStyle(tint == .secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
      .padding(.horizontal, 5)
      .background(tint.opacity(tint == .secondary ? 0.15 : 0.14), in: Capsule())
  }
}

private struct ShareBar: View {
  let fraction: Double

  var body: some View {
    GeometryReader { proxy in
      Capsule()
        .fill(Color.blue.opacity(0.7))
        .frame(width: max(2, proxy.size.width * fraction))
    }
    .frame(height: 3)
  }
}
