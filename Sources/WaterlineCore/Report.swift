import Foundation

/// The machine-readable reading printed by `Waterline --json`. All sizes are bytes.
public struct Report: Sendable, Codable {
  public struct Memory: Sendable, Codable {
    public let total, used, app, wired, compressed, cached, free, available: UInt64
    public let swapUsed, swapTotal: UInt64
    public let usedPercent: Double
    public let pressure: String
    public let pressurePercent: Int
  }

  public struct App: Sendable, Codable {
    public let name: String
    public let bundlePath: String?
    public let footprint: UInt64
    public let isElectron: Bool
    public let processes: [Process]
  }

  public struct Process: Sendable, Codable {
    public let pid: Int32
    public let name: String
    public let footprint: UInt64
  }

  public let timestamp: Date
  public let memory: Memory
  public let verdict: MemoryVerdict
  public let gpuMemoryLimit: UInt64
  public let apps: [App]
  public let unreadableProcessCount: Int

  public static func current() -> Report {
    let memory = SystemMemory.current()
    let snapshot = ProcessSampler.snapshot()
    return Report(
      timestamp: Date(),
      memory: Memory(
        total: memory.total, used: memory.used, app: memory.app, wired: memory.wired,
        compressed: memory.compressed, cached: memory.cached, free: memory.free,
        available: memory.available, swapUsed: memory.swapUsed, swapTotal: memory.swapTotal,
        usedPercent: (memory.usedFraction * 1000).rounded() / 10,
        pressure: memory.pressure.label.lowercased(), pressurePercent: memory.pressurePercent),
      verdict: VerdictEngine.evaluate(memory: memory, swapGrowth: 0, topApp: snapshot.groups.first),
      gpuMemoryLimit: GPUBudget.current(totalMemory: memory.total).limit,
      apps: snapshot.groups.map { group in
        App(
          name: group.name, bundlePath: group.bundlePath, footprint: group.footprint,
          isElectron: group.isElectron,
          processes: group.processes.map { Process(pid: $0.pid, name: $0.name, footprint: $0.footprint) })
      },
      unreadableProcessCount: snapshot.unreadableCount)
  }

  public func json() throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return String(decoding: try encoder.encode(self), as: UTF8.self)
  }
}
