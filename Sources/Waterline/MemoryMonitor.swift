import Foundation
import WaterlineCore
import Observation

/// The app's single source of truth. Reads system memory every 2 seconds for the menu
/// bar, scans processes every 30 seconds in the background (for leak detection) and every
/// 2 seconds while the panel is open, and keeps a minute-by-minute 24-hour history.
@Observable
final class MemoryMonitor {
  static let shared = MemoryMonitor()

  static let interval: Duration = .seconds(2)
  static let liveLength = 90  // 3 minutes of 2-second samples
  static let backgroundScanInterval: TimeInterval = 30
  static let swapWindow: TimeInterval = 5 * 60

  private(set) var system: SystemMemory
  private(set) var live: [Double] = []
  private(set) var processes = ProcessSnapshot()
  private(set) var verdict: MemoryVerdict
  private(set) var usage: UsageHistory
  private(set) var leaks = LeakDetector()
  private(set) var gpu: GPUBudget

  @ObservationIgnored private var panelVisible = false
  @ObservationIgnored private var isScanning = false
  @ObservationIgnored private var lastScan = Date.distantPast
  @ObservationIgnored private var swapSamples: [(time: Date, bytes: UInt64)] = []
  @ObservationIgnored private var minuteStart = Date()
  @ObservationIgnored private var minutePeak: UsagePoint?
  @ObservationIgnored private var lastSave = Date()
  @ObservationIgnored private var alerts = AlertState()
  @ObservationIgnored private var loop: Task<Void, Never>?

  private init() {
    let memory = SystemMemory.current()
    system = memory
    gpu = .current(totalMemory: memory.total)
    usage = HistoryStore.load()
    verdict = VerdictEngine.evaluate(memory: memory, swapGrowth: 0, topApp: nil)
    loop = Task { [weak self] in
      while !Task.isCancelled {
        self?.tick()
        try? await Task.sleep(for: Self.interval)
      }
    }
  }

  var suspects: [GrowthReport] { leaks.suspects() }

  func setPanelVisible(_ visible: Bool) {
    let becameVisible = visible && !panelVisible
    panelVisible = visible
    if becameVisible { scanProcesses() }
  }

  /// Rescan shortly after quitting something, once the app has had a moment to exit.
  func rescanSoon() {
    Task {
      try? await Task.sleep(for: .seconds(1.5))
      scanProcesses()
    }
  }

  func saveHistory() {
    HistoryStore.save(usage)
    lastSave = Date()
  }

  // MARK: - Sampling

  private func tick() {
    let now = Date()
    system = .current()

    live.append(system.usedFraction)
    if live.count > Self.liveLength { live.removeFirst(live.count - Self.liveLength) }

    swapSamples.append((now, system.swapUsed))
    swapSamples.removeAll { now.timeIntervalSince($0.time) > Self.swapWindow }

    recordUsage(at: now)
    updateVerdict()
    checkPressureAlert()

    if panelVisible || now.timeIntervalSince(lastScan) >= Self.backgroundScanInterval {
      scanProcesses()
    }
    if now.timeIntervalSince(lastSave) >= 5 * 60 { saveHistory() }

    // The GPU cap only changes if someone runs sysctl; once a minute is plenty.
    if Int(now.timeIntervalSince1970) % 60 < 2 { gpu = .current(totalMemory: system.total) }
  }

  private var swapGrowth: Int64 {
    guard let first = swapSamples.first, let last = swapSamples.last else { return 0 }
    return Int64(last.bytes) - Int64(first.bytes)
  }

  private func updateVerdict() {
    let next = VerdictEngine.evaluate(memory: system, swapGrowth: swapGrowth, topApp: processes.groups.first)
    if next != verdict { verdict = next }
  }

  private func recordUsage(at now: Date) {
    let point = UsagePoint(
      time: now, usedFraction: system.usedFraction, pressure: system.pressure, swapUsed: system.swapUsed)
    minutePeak = minutePeak.map { $0.peak(with: point) } ?? point
    guard now.timeIntervalSince(minuteStart) >= UsageHistory.pointInterval, let peak = minutePeak else { return }
    usage.append(peak)
    minuteStart = now
    minutePeak = nil
  }

  private func scanProcesses() {
    guard !isScanning else { return }
    isScanning = true
    lastScan = Date()
    Task {
      let snapshot = await ProcessSampler.sample()
      processes = snapshot
      isScanning = false
      if leaks.record(snapshot.groups, at: Date()) { checkLeakAlerts() }
    }
  }

  // MARK: - Alerts

  private struct AlertState {
    var notifiedPressure = MemoryPressure.normal
    var elevatedTicks = 0
    var calmTicks = 0
    var leakNotified: [String: Date] = [:]
  }

  /// Notifies when pressure rises and stays up for ~6 seconds, so brief spikes don't nag.
  /// Pressure has to stay lower for a minute before the next rise notifies again.
  private func checkPressureAlert() {
    let pressure = system.pressure
    if pressure > alerts.notifiedPressure {
      alerts.calmTicks = 0
      alerts.elevatedTicks += 1
      guard alerts.elevatedTicks >= 3 else { return }
      alerts.notifiedPressure = pressure
      alerts.elevatedTicks = 0
      Notifier.post(id: "pressure", title: verdict.headline, body: verdict.detail)
    } else if pressure < alerts.notifiedPressure {
      alerts.elevatedTicks = 0
      alerts.calmTicks += 1
      if alerts.calmTicks >= 30 {
        alerts.notifiedPressure = pressure
        alerts.calmTicks = 0
      }
    } else {
      alerts.elevatedTicks = 0
      alerts.calmTicks = 0
    }
  }

  private func checkLeakAlerts() {
    let now = Date()
    for suspect in leaks.suspects() {
      if let last = alerts.leakNotified[suspect.appID], now.timeIntervalSince(last) < 3 * 60 * 60 { continue }
      alerts.leakNotified[suspect.appID] = now
      Notifier.post(
        id: "leak-\(suspect.appID)",
        title: "\(suspect.name) keeps growing",
        body: "It gained \(Bytes.format(UInt64(max(0, suspect.growth)))) in \(Int(suspect.duration / 60)) minutes and hasn't given any back. Restarting it usually frees that memory.")
    }
  }
}

enum HistoryStore {
  static var url: URL {
    URL.applicationSupportDirectory.appending(path: "Waterline/history.json")
  }

  static func load() -> UsageHistory {
    guard let data = try? Data(contentsOf: url),
          var history = try? JSONDecoder().decode(UsageHistory.self, from: data) else {
      return UsageHistory()
    }
    history.trim(now: Date())
    return history
  }

  static func save(_ history: UsageHistory) {
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(history).write(to: url, options: .atomic)
    } catch {
      // History is a convenience; losing a save is fine.
    }
  }
}
