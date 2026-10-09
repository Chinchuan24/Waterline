import AppKit
import WaterlineCore
import SwiftUI
import UserNotifications

@main
enum Entry {
  static func main() {
    let arguments = CommandLine.arguments
    if arguments.contains("--help") || arguments.contains("-h") {
      print("""
        Waterline — RAM monitor for Mac (Apple Silicon and Intel)

          Waterline                     run the menu bar app
          Waterline --json              print a machine-readable reading and exit
          Waterline --dump              print a human-readable reading and exit
          Waterline --snapshot <dir>    render the UI to PNGs (for docs and UI work)
        """)
    } else if arguments.contains("--json") {
      do {
        print(try Report.current().json())
      } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
      }
    } else if arguments.contains("--dump") {
      Dump.run()
    } else if let flag = arguments.firstIndex(of: "--snapshot"), arguments.indices.contains(flag + 1) {
      Snapshot.run(into: arguments[flag + 1])
    } else {
      WaterlineApp.main()
    }
  }
}

struct WaterlineApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  private let monitor = MemoryMonitor.shared

  init() {
    // The bundled app sets LSUIElement; this keeps `swift run` out of the Dock too.
    NSApplication.shared.setActivationPolicy(.accessory)
  }

  var body: some Scene {
    MenuBarExtra {
      MemoryPanel(monitor: monitor)
    } label: {
      MenuBarLabel(monitor: monitor)
    }
    .menuBarExtraStyle(.window)
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    Settings.registerDefaults()
    if Notifier.isSupported {
      UNUserNotificationCenter.current().delegate = self
      Notifier.requestAuthorization()
    }
    FloatingMeter.shared.applySavedPreference()

    // SwiftUI apps can be terminated without applicationWillTerminate at logout or
    // shutdown, so also save history whenever the Mac is about to sleep or power off.
    let workspace = NSWorkspace.shared.notificationCenter
    for name in [NSWorkspace.willPowerOffNotification, NSWorkspace.willSleepNotification] {
      workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { MemoryMonitor.shared.saveHistory() }
      }
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    MemoryMonitor.shared.saveHistory()
  }

  // Menu bar apps count as frontmost while their panel is open; show banners anyway.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .sound]
  }
}

/// `Waterline --dump` prints one reading to the terminal.
enum Dump {
  static func run() {
    let report = Report.current()
    let memory = report.memory
    let gpu = report.gpuMemoryLimit
    print("""
      \(report.verdict.headline)
        \(report.verdict.detail)

      Physical   \(Bytes.format(memory.total, gbDecimals: 2))
      Used       \(Bytes.format(memory.used, gbDecimals: 2))  (\(memory.usedPercent)%)
        App      \(Bytes.format(memory.app, gbDecimals: 2))
        Wired    \(Bytes.format(memory.wired, gbDecimals: 2))
        Compr.   \(Bytes.format(memory.compressed, gbDecimals: 2))
      Cached     \(Bytes.format(memory.cached, gbDecimals: 2))
      Available  \(Bytes.format(memory.available, gbDecimals: 2))
      Swap       \(Bytes.format(memory.swapUsed, gbDecimals: 2)) of \(Bytes.format(memory.swapTotal, gbDecimals: 2))
      Pressure   \(memory.pressure) (\(memory.pressurePercent)%)
      GPU limit  \(Bytes.format(gpu, gbDecimals: 1))

      Top apps (\(report.unreadableProcessCount) system processes unreadable):
      """)
    for app in report.apps.prefix(15) {
      let size = Bytes.format(app.footprint).padding(toLength: 9, withPad: " ", startingAt: 0)
      let electron = app.isElectron ? "  ⚛︎ Electron" : ""
      print("  \(size) \(app.name)  [\(app.processes.count) proc]\(electron)")
    }
  }
}
