import WaterlineCore
import SwiftUI

enum Settings {
  static let menuBarStyle = "menuBarStyle"
  static let floatingMeter = "showFloatingMeter"
  static let notifications = "notificationsEnabled"
  static let quantization = "quantization"
  static let panelTab = "panelTab"

  static func registerDefaults() {
    UserDefaults.standard.register(defaults: [notifications: true])
  }
}

enum MenuBarStyle: String, CaseIterable, Identifiable {
  case percent, used, usedOfTotal, gaugeOnly

  var id: Self { self }

  var title: String {
    switch self {
    case .percent: "Percentage"
    case .used: "Memory Used"
    case .usedOfTotal: "Used / Total"
    case .gaugeOnly: "Gauge Only"
    }
  }

  func text(for memory: SystemMemory) -> String? {
    switch self {
    case .percent: "\(Int((memory.usedFraction * 100).rounded()))%"
    case .used: Bytes.format(memory.used)
    case .usedOfTotal:
      "\(Bytes.format(memory.used).replacingOccurrences(of: " GB", with: ""))/\(Bytes.format(memory.total, gbDecimals: 0))"
    case .gaugeOnly: nil
    }
  }
}

extension MemoryVerdict.Level {
  var color: Color {
    switch self {
    case .relaxed: .green
    case .fine: .mint
    case .tight: .orange
    case .critical: .red
    }
  }

  var symbol: String {
    switch self {
    case .relaxed, .fine: "checkmark.circle.fill"
    case .tight: "exclamationmark.circle.fill"
    case .critical: "exclamationmark.octagon.fill"
    }
  }
}

extension MemoryPressure {
  var color: Color {
    switch self {
    case .normal: .green
    case .warning: .yellow
    case .critical: .red
    }
  }
}
