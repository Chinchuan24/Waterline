import Darwin
import Foundation

public struct ProcessSample: Sendable, Identifiable, Hashable {
  public let pid: pid_t
  public let name: String
  /// `phys_footprint` — the number Activity Monitor shows in its "Memory" column.
  public let footprint: UInt64
  public var id: pid_t { pid }

  public init(pid: pid_t, name: String, footprint: UInt64) {
    self.pid = pid
    self.name = name
    self.footprint = footprint
  }
}

/// One application (or a standalone process) with every process that belongs to it.
public struct AppGroup: Sendable, Identifiable {
  public let id: String
  public let name: String
  public let bundlePath: String?
  public let processes: [ProcessSample]
  public let footprint: UInt64
  /// Built on Electron, so it ships its own copy of Chromium.
  public let isElectron: Bool

  public init(
    id: String, name: String, bundlePath: String? = nil, processes: [ProcessSample],
    isElectron: Bool = false
  ) {
    self.id = id
    self.name = name
    self.bundlePath = bundlePath
    self.processes = processes
    self.footprint = processes.reduce(0) { $0 + $1.footprint }
    self.isElectron = isElectron
  }
}

public struct ProcessSnapshot: Sendable {
  public var groups: [AppGroup]
  /// Processes owned by other users (root, _windowserver, …) that an unprivileged app can't read.
  public var unreadableCount: Int
  public var measuredTotal: UInt64

  public init(groups: [AppGroup] = [], unreadableCount: Int = 0, measuredTotal: UInt64 = 0) {
    self.groups = groups
    self.unreadableCount = unreadableCount
    self.measuredTotal = measuredTotal
  }

  public var electronApps: [AppGroup] { groups.filter(\.isElectron) }
}

public enum ProcessSampler {
  /// A full scan is a few hundred syscalls (~20–30 ms), long enough to drop frames,
  /// so UI callers run it off the main actor.
  @concurrent
  public static func sample() async -> ProcessSnapshot {
    snapshot()
  }

  public static func snapshot() -> ProcessSnapshot {
    var snapshot = ProcessSnapshot()
    var paths: [pid_t: String] = [:]
    var buckets: [String: (name: String, bundle: String?, processes: [ProcessSample])] = [:]

    func path(of pid: pid_t) -> String? {
      if let cached = paths[pid] { return cached }
      let found = executablePath(of: pid)
      paths[pid] = found
      return found
    }

    for pid in allPIDs() where pid > 0 {
      guard let footprint = footprint(of: pid) else {
        snapshot.unreadableCount += 1
        continue
      }
      let ownPath = path(of: pid)
      let name = ownPath.map { ($0 as NSString).lastPathComponent } ?? processName(of: pid)

      // Attribute helpers to their app: first by the .app bundle they live in
      // (Chrome/Electron helpers), then by the process macOS holds responsible
      // for them (Safari's WebKit processes, a language server spawned by an editor).
      let bundle = ownPath.flatMap(outermostAppBundle)
        ?? responsiblePID(for: pid).flatMap { path(of: $0) }.flatMap(outermostAppBundle)

      let key = bundle ?? "process:\(name)"
      if buckets[key] == nil {
        buckets[key] = (bundle.map(appDisplayName) ?? name, bundle, [])
      }
      buckets[key]!.processes.append(ProcessSample(pid: pid, name: name, footprint: footprint))
      snapshot.measuredTotal += footprint
    }

    snapshot.groups = buckets.map { key, bucket in
      AppGroup(
        id: key,
        name: bucket.name,
        bundlePath: bucket.bundle,
        processes: bucket.processes.sorted { $0.footprint > $1.footprint },
        isElectron: bucket.bundle.map(isElectronApp) ?? false)
    }
    .sorted { ($0.footprint, $1.name) > ($1.footprint, $0.name) }
    return snapshot
  }

  // MARK: - libproc

  static func allPIDs() -> [pid_t] {
    let estimate = proc_listallpids(nil, 0)
    guard estimate > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
    let written = pids.withUnsafeMutableBytes {
      proc_listallpids($0.baseAddress, Int32($0.count))
    }
    return written > 0 ? Array(pids.prefix(Int(written))) : []
  }

  static func footprint(of pid: pid_t) -> UInt64? {
    var usage = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &usage) {
      $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
      }
    }
    return result == 0 ? usage.ri_phys_footprint : nil
  }

  static func executablePath(of pid: pid_t) -> String? {
    var buffer = [UInt8](repeating: 0, count: 4096)  // PROC_PIDPATHINFO_MAXSIZE
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
  }

  static func processName(of pid: pid_t) -> String {
    var buffer = [UInt8](repeating: 0, count: 256)
    let length = proc_name(pid, &buffer, UInt32(buffer.count))
    return length > 0 ? String(decoding: buffer.prefix(Int(length)), as: UTF8.self) : "pid \(pid)"
  }

  /// "/Applications/Google Chrome.app/Contents/Frameworks/…/Helper.app/…" → "/Applications/Google Chrome.app"
  public static func outermostAppBundle(_ path: String) -> String? {
    guard let range = path.range(of: ".app/") else { return nil }
    return String(path[..<range.lowerBound]) + ".app"
  }

  static func appDisplayName(_ bundlePath: String) -> String {
    let info = Bundle(path: bundlePath)?.infoDictionary
    let name = (info?["CFBundleDisplayName"] as? String)
      ?? (info?["CFBundleName"] as? String)
      ?? ((bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
    // Some bundles (e.g. WhatsApp) embed invisible direction marks in their name.
    return name.trimmingCharacters(in: .controlCharacters)
  }

  static func isElectronApp(_ bundlePath: String) -> Bool {
    FileManager.default.fileExists(
      atPath: bundlePath + "/Contents/Frameworks/Electron Framework.framework")
  }

  // The same responsibility tracking Activity Monitor and Energy use. It isn't in a
  // public header, so resolve it at runtime and degrade gracefully if it ever disappears.
  private typealias ResponsibleFunction = @convention(c) (pid_t) -> pid_t
  private static let responsibleFunction: ResponsibleFunction? = {
    let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
    guard let symbol = dlsym(rtldDefault, "responsibility_get_pid_responsible_for_pid") else {
      return nil
    }
    return unsafeBitCast(symbol, to: ResponsibleFunction.self)
  }()

  static func responsiblePID(for pid: pid_t) -> pid_t? {
    guard let responsible = responsibleFunction?(pid), responsible > 0, responsible != pid else {
      return nil
    }
    return responsible
  }
}
