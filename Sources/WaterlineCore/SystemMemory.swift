import Darwin
import Foundation

/// The kernel's own view of memory pressure (`kern.memorystatus_vm_pressure_level`).
public enum MemoryPressure: Int, Sendable, Codable, Comparable {
  case normal = 1
  case warning = 2
  case critical = 4

  public var label: String {
    switch self {
    case .normal: "Normal"
    case .warning: "Warning"
    case .critical: "Critical"
    }
  }

  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A system-wide memory reading, broken down the same way Activity Monitor does it.
///
/// - Memory Used = App + Wired + Compressed
/// - Cached Files = file-backed + purgeable pages (reclaimable instantly, so not "used")
public struct SystemMemory: Sendable, Equatable {
  public var total: UInt64
  public var app: UInt64
  public var wired: UInt64
  public var compressed: UInt64
  public var cached: UInt64
  public var swapUsed: UInt64
  public var swapTotal: UInt64
  public var pressure: MemoryPressure
  /// 0–100, the inverse of the kernel's "free memory percentage" (what `memory_pressure` prints).
  public var pressurePercent: Int

  public init(
    total: UInt64 = 0, app: UInt64 = 0, wired: UInt64 = 0, compressed: UInt64 = 0,
    cached: UInt64 = 0, swapUsed: UInt64 = 0, swapTotal: UInt64 = 0,
    pressure: MemoryPressure = .normal, pressurePercent: Int = 0
  ) {
    self.total = total
    self.app = app
    self.wired = wired
    self.compressed = compressed
    self.cached = cached
    self.swapUsed = swapUsed
    self.swapTotal = swapTotal
    self.pressure = pressure
    self.pressurePercent = pressurePercent
  }

  public var used: UInt64 { app + wired + compressed }
  public var free: UInt64 { total > used + cached ? total - used - cached : 0 }
  /// What apps can get without anything being compressed or swapped: free + cached files.
  public var available: UInt64 { total > used ? total - used : 0 }
  public var usedFraction: Double { total == 0 ? 0 : Double(used) / Double(total) }

  public static func current() -> SystemMemory {
    var memory = SystemMemory(total: ProcessInfo.processInfo.physicalMemory)

    if let vm = vmStatistics() {
      let page = pageSize
      memory.app = UInt64(vm.internal_page_count &- vm.purgeable_count) * page
      memory.wired = UInt64(vm.wire_count) * page
      memory.compressed = UInt64(vm.compressor_page_count) * page
      memory.cached = UInt64(vm.external_page_count &+ vm.purgeable_count) * page
    }

    if let swap = swapUsage() {
      memory.swapUsed = swap.xsu_used
      memory.swapTotal = swap.xsu_total
    }

    if let level = Sysctl.integer("kern.memorystatus_vm_pressure_level") {
      memory.pressure = MemoryPressure(rawValue: Int(level)) ?? .normal
    }
    if let freePercent = Sysctl.integer("kern.memorystatus_level") {
      memory.pressurePercent = max(0, min(100, 100 - Int(freePercent)))
    }
    return memory
  }

  // MARK: - Kernel queries

  // `mach_host_self()` allocates a send right on every call, so take it once.
  private static let host = mach_host_self()

  private static let pageSize: UInt64 = {
    var size: vm_size_t = 0
    return host_page_size(host, &size) == KERN_SUCCESS ? UInt64(size) : UInt64(getpagesize())
  }()

  private static func vmStatistics() -> vm_statistics64? {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(
      MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &stats) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics64(host, HOST_VM_INFO64, $0, &count)
      }
    }
    return result == KERN_SUCCESS ? stats : nil
  }

  private static func swapUsage() -> xsw_usage? {
    var usage = xsw_usage()
    var size = MemoryLayout<xsw_usage>.size
    return sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 ? usage : nil
  }
}

enum Sysctl {
  /// Reads an integer sysctl of any width (int, int64).
  static func integer(_ name: String) -> Int64? {
    var value: Int64 = 0
    var size = MemoryLayout<Int64>.size
    return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
  }
}

public enum Bytes {
  /// "9.84 GB", "512 MB" — binary units, matching Activity Monitor.
  public static func format(_ bytes: UInt64, gbDecimals: Int = 1) -> String {
    let gb = Double(bytes) / 1_073_741_824
    if gb >= 1 { return String(format: "%.\(gbDecimals)f GB", gb) }
    let mb = Double(bytes) / 1_048_576
    if mb >= 1 || bytes == 0 { return String(format: "%.0f MB", mb) }
    return String(format: "%.0f KB", Double(bytes) / 1024)
  }

  public static let gigabyte: UInt64 = 1_073_741_824
  public static let megabyte: UInt64 = 1_048_576
}
