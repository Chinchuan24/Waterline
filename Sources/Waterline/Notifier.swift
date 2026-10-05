import Foundation
import UserNotifications

enum Notifier {
  /// UserNotifications needs a bundle identifier; a bare `swift run` binary has none.
  static var isSupported: Bool { Bundle.main.bundleIdentifier != nil }

  static func requestAuthorization() {
    guard isSupported else { return }
    Task {
      _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }
  }

  static func post(id: String, title: String, body: String) {
    guard isSupported, UserDefaults.standard.bool(forKey: Settings.notifications) else { return }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
    Task {
      try? await UNUserNotificationCenter.current().add(request)
    }
  }
}
