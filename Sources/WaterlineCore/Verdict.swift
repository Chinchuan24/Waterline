import Foundation

/// A one-sentence answer to "should I worry about memory right now?"
///
/// Most people judge memory by how full the bar is, but macOS deliberately keeps RAM
/// full of cache. The signals that actually mean trouble are memory pressure and swap
/// growth, so the verdict is built from those.
public struct MemoryVerdict: Sendable, Equatable, Codable {
  public enum Level: String, Sendable, Codable, Comparable, CaseIterable {
    case relaxed, fine, tight, critical

    var severity: Int {
      switch self {
      case .relaxed: 0
      case .fine: 1
      case .tight: 2
      case .critical: 3
      }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.severity < rhs.severity }
  }

  public let level: Level
  public let headline: String
  public let detail: String

  public init(level: Level, headline: String, detail: String) {
    self.level = level
    self.headline = headline
    self.detail = detail
  }
}

public enum VerdictEngine {
  /// Swap growth over the trailing window that counts as "started swapping".
  public static let swapGrowthThreshold: Int64 = 512 * 1_048_576

  /// - Parameters:
  ///   - swapGrowth: bytes added to swap over roughly the last five minutes.
  ///   - topApp: the app using the most memory, to suggest what to quit.
  public static func evaluate(
    memory: SystemMemory, swapGrowth: Int64, topApp: AppGroup?
  ) -> MemoryVerdict {
    let suggestion = topApp.map { " Quitting \($0.name) would free about \(Bytes.format($0.footprint))." } ?? ""

    switch memory.pressure {
    case .critical:
      return MemoryVerdict(
        level: .critical,
        headline: "Your Mac is out of memory",
        detail: "macOS is swapping to disk, so apps will stutter.\(suggestion)")
    case .warning:
      return MemoryVerdict(
        level: .tight,
        headline: "Memory is getting tight",
        detail: "macOS is compressing memory to keep up.\(suggestion)")
    case .normal:
      break
    }

    if swapGrowth >= swapGrowthThreshold {
      return MemoryVerdict(
        level: .tight,
        headline: "Your Mac started swapping",
        detail: "\(Bytes.format(UInt64(swapGrowth))) moved to disk in the last few minutes. Things may slow down if it keeps growing.\(suggestion)")
    }

    let cacheNote = memory.total > 0 && Double(memory.cached) / Double(memory.total) >= 0.2
      ? " \(Bytes.format(memory.cached)) more is file cache that macOS hands back instantly."
      : ""

    if memory.usedFraction >= 0.85 {
      return MemoryVerdict(
        level: .fine,
        headline: "You're fine, but close to the limit",
        detail: "Pressure is low and \(Bytes.format(memory.available)) is available. Opening something big may tip it over.")
    }

    return MemoryVerdict(
      level: memory.usedFraction >= 0.7 ? .fine : .relaxed,
      headline: "Plenty of headroom",
      detail: "Pressure is low and \(Bytes.format(memory.free)) is sitting completely free.\(cacheNote)")
  }
}
