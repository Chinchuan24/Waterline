import AppKit
import WaterlineCore
import SwiftUI

/// The menu bar item: a battery-style fill gauge plus a number.
///
/// Rendered to a template image so it gets exact monospaced digits (no jitter as the
/// value ticks) while still taking the menu bar's own light/dark tint.
struct MenuBarLabel: View {
  let monitor: MemoryMonitor
  @AppStorage(Settings.menuBarStyle) private var style: MenuBarStyle = .percent

  var body: some View {
    Image(nsImage: Self.render(memory: monitor.system, style: style))
      .accessibilityLabel(
        "Memory used \(Bytes.format(monitor.system.used)) of \(Bytes.format(monitor.system.total, gbDecimals: 0))")
  }

  static func render(memory: SystemMemory, style: MenuBarStyle) -> NSImage {
    let content = HStack(spacing: 4) {
      if memory.pressure != .normal {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 11, weight: .semibold))
      }
      FillGauge(fraction: memory.usedFraction)
      if let text = style.text(for: memory) {
        Text(text)
          .font(.system(size: 12.5, weight: .medium).monospacedDigit())
      }
    }
    .foregroundStyle(.black)
    .fixedSize()

    let renderer = ImageRenderer(content: content)
    renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
    let image = renderer.nsImage ?? NSImage()
    image.isTemplate = true
    return image
  }
}

struct FillGauge: View {
  let fraction: Double

  var body: some View {
    let height: CGFloat = 13
    ZStack(alignment: .bottom) {
      RoundedRectangle(cornerRadius: 2.5)
        .strokeBorder(lineWidth: 1.2)
      RoundedRectangle(cornerRadius: 1.2)
        .frame(height: max(1.5, (height - 4.4) * min(1, max(0, fraction))))
        .padding(2.2)
    }
    .frame(width: 7, height: height)
  }
}
