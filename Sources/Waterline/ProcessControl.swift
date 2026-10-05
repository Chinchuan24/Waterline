import AppKit
import Darwin
import WaterlineCore

/// Quitting apps and ending processes — the only honest way to free RAM on a Mac.
///
/// Apps are asked to quit the normal way (like ⌘Q), so anything with unsaved work gets
/// the chance to prompt. Processes the system depends on are refused outright: ending
/// `loginwindow`, for example, logs you out on the spot.
enum ProcessControl {
  static let protectedNames: Set<String> = [
    "loginwindow", "launchd", "WindowServer", "kernel_task", "Dock", "SystemUIServer",
    "ControlCenter", "WindowManager", "NotificationCenter", "Finder", "Spotlight",
    "cfprefsd", "distnoted", "UserEventAgent", "universalaccessd", "coreaudiod",
    "TextInputMenuAgent", "talagent", "secd", "trustd", "Waterline",
  ]

  private static let ownBundlePath = Bundle.main.bundlePath

  // MARK: Apps

  static func runningApps(for group: AppGroup) -> [NSRunningApplication] {
    guard let bundlePath = group.bundlePath else { return [] }
    return NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == bundlePath }
  }

  static func isProtected(_ group: AppGroup) -> Bool {
    protectedNames.contains(group.name)
      || group.bundlePath == ownBundlePath
      || group.processes.contains { protectedNames.contains($0.name) || $0.pid == getpid() }
  }

  /// Something the user can close from the row: a running app, or a standalone tool's processes.
  static func canClose(_ group: AppGroup) -> Bool {
    !isProtected(group) && (group.bundlePath == nil || !runningApps(for: group).isEmpty)
  }

  static func close(_ group: AppGroup, force: Bool = false) {
    let apps = runningApps(for: group)
    if apps.isEmpty {
      // Not an app (e.g. `node`, `python3`): signal its processes directly.
      group.processes.forEach { end($0, force: force) }
    } else {
      for app in apps {
        if force { app.forceTerminate() } else { app.terminate() }
      }
    }
  }

  /// Regular Dock apps that "Quit All Apps" will close — never Finder, never Waterline,
  /// never menu bar utilities or background services.
  static func quitAllCandidates(in snapshot: ProcessSnapshot) -> [AppGroup] {
    snapshot.groups.filter { group in
      !isProtected(group)
        && runningApps(for: group).contains { $0.activationPolicy == .regular }
    }
  }

  static func quitAll(in snapshot: ProcessSnapshot) {
    for group in quitAllCandidates(in: snapshot) {
      for app in runningApps(for: group) where app.activationPolicy == .regular {
        app.terminate()
      }
    }
  }

  // MARK: Processes

  static func canEnd(_ process: ProcessSample) -> Bool {
    process.pid > 1 && process.pid != getpid() && !protectedNames.contains(process.name)
  }

  @discardableResult
  static func end(_ process: ProcessSample, force: Bool = false) -> Bool {
    guard canEnd(process) else { return false }
    return kill(process.pid, force ? SIGKILL : SIGTERM) == 0
  }
}
