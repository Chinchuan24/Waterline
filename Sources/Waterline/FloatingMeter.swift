import AppKit
import WaterlineCore
import SwiftUI

/// An optional always-on-top meter you can drag to any corner. It floats over every
/// Space and full-screen app, never takes focus, and remembers where you put it.
final class FloatingMeter {
  static let shared = FloatingMeter()
  private static let frameName = "WaterlineFloatingMeter"

  private var panel: NSPanel?

  func applySavedPreference() {
    setVisible(UserDefaults.standard.bool(forKey: Settings.floatingMeter))
  }

  func setVisible(_ visible: Bool) {
    if visible {
      if panel == nil { panel = makePanel() }
      panel?.orderFrontRegardless()
    } else {
      panel?.orderOut(nil)
    }
  }

  private func makePanel() -> NSPanel {
    let host = NSHostingView(rootView: FloatingMeterView(monitor: .shared))
    let panel = NSPanel(
      contentRect: NSRect(origin: .zero, size: host.fittingSize),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    panel.contentView = host
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
    panel.isMovableByWindowBackground = true
    panel.hidesOnDeactivate = false
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true

    if !panel.setFrameUsingName(Self.frameName), let screen = NSScreen.main?.visibleFrame {
      panel.setFrameOrigin(NSPoint(
        x: screen.maxX - panel.frame.width - 16,
        y: screen.maxY - panel.frame.height - 16))
    }
    panel.setFrameAutosaveName(Self.frameName)
    return panel
  }
}

struct FloatingMeterView: View {
  let monitor: MemoryMonitor

  var body: some View {
    let memory = monitor.system
    let tint = monitor.verdict.level.color
    HStack(spacing: 10) {
      ZStack {
        Circle().stroke(.quaternary, lineWidth: 4)
        Circle()
          .trim(from: 0, to: memory.usedFraction)
          .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
          .rotationEffect(.degrees(-90))
          .animation(.smooth(duration: 0.6), value: memory.usedFraction)
        Text("\(Int((memory.usedFraction * 100).rounded()))")
          .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
      }
      .frame(width: 34, height: 34)

      VStack(alignment: .leading, spacing: 1) {
        Text(Bytes.format(memory.used))
          .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
        HStack(spacing: 4) {
          Circle().fill(memory.pressure.color).frame(width: 6, height: 6)
          Text("Pressure \(memory.pressure.label.lowercased())")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .frame(width: 176, alignment: .leading)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
    .help("Drag to move. Right-click to hide.")
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(MenuBarLabel.spokenSummary(memory))
    .contextMenu {
      Button("Hide Floating Meter") {
        UserDefaults.standard.set(false, forKey: Settings.floatingMeter)
        FloatingMeter.shared.setVisible(false)
      }
    }
  }
}
