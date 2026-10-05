import Foundation

public struct UsagePoint: Sendable, Equatable, Codable {
  public let time: Date
  public let usedFraction: Double
  public let pressure: MemoryPressure
  public let swapUsed: UInt64

  public init(time: Date, usedFraction: Double, pressure: MemoryPressure, swapUsed: UInt64) {
    self.time = time
    self.usedFraction = usedFraction
    self.pressure = pressure
    self.swapUsed = swapUsed
  }

  /// The worst of two readings — so a one-minute point keeps that minute's spike.
  public func peak(with other: UsagePoint) -> UsagePoint {
    UsagePoint(
      time: max(time, other.time),
      usedFraction: max(usedFraction, other.usedFraction),
      pressure: max(pressure, other.pressure),
      swapUsed: max(swapUsed, other.swapUsed))
  }
}

/// One point per minute for the last 24 hours.
public struct UsageHistory: Sendable, Equatable, Codable {
  public static let retention: TimeInterval = 24 * 60 * 60
  public static let pointInterval: TimeInterval = 60

  public private(set) var points: [UsagePoint]

  public init(points: [UsagePoint] = []) {
    self.points = points
  }

  public mutating func append(_ point: UsagePoint) {
    points.append(point)
    trim(now: point.time)
  }

  public mutating func trim(now: Date) {
    let cutoff = now.addingTimeInterval(-Self.retention)
    points.removeAll { $0.time < cutoff }
  }

  public var peak: UsagePoint? { points.max { $0.usedFraction < $1.usedFraction } }

  public var averageUsed: Double? {
    points.isEmpty ? nil : points.reduce(0) { $0 + $1.usedFraction } / Double(points.count)
  }

  public var timeUnderPressure: TimeInterval {
    Double(points.count { $0.pressure > .normal }) * Self.pointInterval
  }

  public var peakSwap: UInt64 { points.map(\.swapUsed).max() ?? 0 }
}
