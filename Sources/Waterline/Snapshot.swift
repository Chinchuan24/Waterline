import AppKit
import WaterlineCore
import SwiftUI

/// `Waterline --snapshot <dir>` renders every panel tab (light + dark), the floating meter,
/// and the menu bar label to PNGs without touching the real menu bar — used for the
/// README screenshots and for checking UI changes.
enum Snapshot {
  static func run(into directory: String) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let monitor = MemoryMonitor.shared
    monitor.setPanelVisible(true)

    Task {
      try? await Task.sleep(for: .seconds(10))  // let a few live samples accumulate
      let folder = URL(fileURLWithPath: directory)
      try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let defaults = UserDefaults.standard
      let savedTab = defaults.string(forKey: Settings.panelTab)

      for tab in PanelTab.allCases {
        defaults.set(tab.rawValue, forKey: Settings.panelTab)
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
          render(MemoryPanel(monitor: monitor).background(.windowBackground),
                 appearance: appearance, to: folder.appending(path: "panel-\(tab.rawValue)-\(suffix).png"))
        }
      }
      defaults.set(savedTab, forKey: Settings.panelTab)

      for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        render(FloatingMeterView(monitor: monitor).padding(20),
               appearance: appearance, to: folder.appending(path: "floating-\(suffix).png"))
      }
      for style in MenuBarStyle.allCases {
        write(MenuBarLabel.render(memory: monitor.system, style: style),
              to: folder.appending(path: "label-\(style.rawValue).png"))
      }
      print("Snapshots written to \(folder.path)")
      exit(0)
    }
    app.run()
  }

  private static func render(_ view: some View, appearance: NSAppearance.Name, to url: URL) {
    let host = NSHostingView(rootView: view)
    host.appearance = NSAppearance(named: appearance)
    host.frame.size = host.fittingSize
    let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    host.display()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
    host.cacheDisplay(in: host.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
  }

  private static func write(_ image: NSImage, to url: URL) {
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
  }
}
