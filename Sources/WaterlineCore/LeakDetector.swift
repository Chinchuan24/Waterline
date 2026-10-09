import Foundation

/// How an app's memory has moved over the time Waterline has been watching it.
public struct GrowthReport: Sendable, Equatable {
  public let appID: String
  public let name: String
  /// Bytes gained along the fitted trend line over `duration`.
  public let growth: Int64
  public let duration: TimeInterval
  /// Steady, sustained growth that never comes back down — the shape of a leak.
  public let isSuspect: Bool
}

/// Watches each app's memory over the last hour and flags the ones that only ever grow.
///
/// An app that grows and then frees memory is just busy. A leak looks different: a
/// rising straight line. So this fits a least-squares line to each app's samples and
/// flags it when the line is both steep (absolute and relative growth) and a good fit
/// (high R²), sustained over at least `minimumDuration`.
public struct LeakDetector: Sendable {
  public struct Sample: Sendable, Equatable {
    public let time: Date
    public let footprint: UInt64
  }

  public var retention: TimeInterval = 60 * 60
  public var sampleInterval: TimeInterval = 30
  public var minimumDuration: TimeInterval = 15 * 60
  public var minimumSamples = 10
  public var minimumGrowth: UInt64 = 400 * 1_048_576
  public var minimumRelativeGrowth = 0.3
  public var minimumFit = 0.8

  public private(set) var samples: [String: [Sample]] = [:]
  private var names: [String: String] = [:]
  private var lastRecord: Date?

  public init() {}

  /// Records one sample per app. Calls closer together than `sampleInterval` are ignored,
  /// so it's safe to call on every refresh. Apps that disappear lose their history, so a
  /// relaunched app starts fresh.
  @discardableResult
  public mutating func record(_ groups: [AppGroup], at time: Date) -> Bool {
    if let lastRecord {
      let gap = time.timeIntervalSince(lastRecord)
      if gap >= 0 && gap < sampleInterval { return false }
      // After sleep (or the clock moving), the old samples aren't comparable: a jump
      // across the gap would read as a perfectly straight leak. Start over.
      if gap < 0 || gap > sampleInterval * 4 { samples.removeAll() }
    }
    lastRecord = time

    var seen = Set<String>()
    for group in groups {
      seen.insert(group.id)
      names[group.id] = group.name
      samples[group.id, default: []].append(Sample(time: time, footprint: group.footprint))
    }

    let cutoff = time.addingTimeInterval(-retention)
    for id in Array(samples.keys) {
      if seen.contains(id) {
        samples[id]!.removeAll { $0.time < cutoff }
      } else {
        samples[id] = nil
        names[id] = nil
      }
    }
    return true
  }

  public func trend(for appID: String) -> [UInt64] {
    samples[appID]?.map(\.footprint) ?? []
  }

  public func report(for appID: String) -> GrowthReport? {
    guard let series = samples[appID], series.count >= 2,
          let first = series.first, let last = series.last else { return nil }
    let duration = last.time.timeIntervalSince(first.time)
    guard duration > 0 else { return nil }

    guard let (slope, fit) = Self.regression(series) else { return nil }
    let growth = slope * duration
    let head = series.prefix(3).map { Double($0.footprint) }
    let baseline = max(head.reduce(0, +) / Double(head.count), 1)

    // An app that ramped up and then levelled off also fits a rising line over the
    // window. A leak is still climbing at the end, so the most recent third of the
    // samples must keep rising at a good fraction of the overall rate.
    let recent = series.suffix(max(4, series.count / 3))
    let stillGrowing = (Self.regression(Array(recent))?.slope ?? 0) >= slope * 0.4

    let isSuspect = duration >= minimumDuration
      && series.count >= minimumSamples
      && growth >= Double(minimumGrowth)
      && growth / baseline >= minimumRelativeGrowth
      && fit >= minimumFit
      && stillGrowing

    return GrowthReport(
      appID: appID, name: names[appID] ?? appID, growth: Int64(growth),
      duration: duration, isSuspect: isSuspect)
  }

  /// Least-squares slope (bytes per second) and R² of footprint over time.
  private static func regression(_ series: [Sample]) -> (slope: Double, fit: Double)? {
    guard series.count >= 2, let start = series.first?.time else { return nil }
    let xs = series.map { $0.time.timeIntervalSince(start) }
    let ys = series.map { Double($0.footprint) }
    let count = Double(series.count)
    let meanX = xs.reduce(0, +) / count
    let meanY = ys.reduce(0, +) / count
    var sxy = 0.0, sxx = 0.0, syy = 0.0
    for (x, y) in zip(xs, ys) {
      sxy += (x - meanX) * (y - meanY)
      sxx += (x - meanX) * (x - meanX)
      syy += (y - meanY) * (y - meanY)
    }
    guard sxx > 0 else { return nil }
    return (sxy / sxx, syy > 0 ? (sxy * sxy) / (sxx * syy) : 0)
  }

  public func suspects() -> [GrowthReport] {
    samples.keys.compactMap(report).filter(\.isSuspect).sorted { $0.growth > $1.growth }
  }
}
