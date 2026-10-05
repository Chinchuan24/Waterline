import AppKit
import SwiftUI

struct AppIcon: View {
  let bundlePath: String?

  var body: some View {
    Group {
      if let bundlePath {
        Image(nsImage: IconCache.icon(for: bundlePath))
          .resizable()
      } else {
        Image(systemName: "gearshape.fill")
          .resizable()
          .scaledToFit()
          .padding(3)
          .foregroundStyle(.secondary)
      }
    }
    .frame(width: 20, height: 20)
  }
}

enum IconCache {
  private static var icons: [String: NSImage] = [:]

  static func icon(for path: String) -> NSImage {
    if let icon = icons[path] { return icon }
    let icon = NSWorkspace.shared.icon(forFile: path)
    icons[path] = icon
    return icon
  }
}

/// A min–max normalized line, for tiny inline trends.
struct Sparkline: Shape {
  let values: [Double]

  func path(in rect: CGRect) -> Path {
    var path = Path()
    guard values.count > 1, let low = values.min(), let high = values.max() else { return path }
    let span = max(high - low, 1)
    let step = rect.width / CGFloat(values.count - 1)
    path.addLines(values.enumerated().map { index, value in
      CGPoint(x: rect.minX + CGFloat(index) * step,
              y: rect.maxY - CGFloat((value - low) / span) * rect.height)
    })
    return path
  }
}

enum ActivityMonitor {
  static func open() {
    let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
    NSWorkspace.shared.openApplication(at: url, configuration: .init())
  }
}

/// Tells the monitor when the panel is on screen, so the fast per-process scan only runs
/// while someone is looking at it.
struct WindowVisibilityObserver: NSViewRepresentable {
  let onChange: (Bool) -> Void

  func makeNSView(context: Context) -> ObserverView {
    let view = ObserverView()
    view.onChange = onChange
    return view
  }

  func updateNSView(_ view: ObserverView, context: Context) {
    view.onChange = onChange
  }

  final class ObserverView: NSView {
    var onChange: ((Bool) -> Void)?
    private var tokens: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      tokens.forEach(NotificationCenter.default.removeObserver)
      tokens = []
      guard let window else {
        onChange?(false)
        return
      }
      let names: [Notification.Name] = [
        NSWindow.didChangeOcclusionStateNotification,
        NSWindow.didBecomeKeyNotification,
        NSWindow.didResignKeyNotification,
      ]
      tokens = names.map { name in
        NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.report() }
        }
      }
      report()
    }

    private func report() {
      guard let window else { return }
      onChange?(window.isVisible && window.occlusionState.contains(.visible))
    }
  }
}
