//
//  NotificationManager.swift
//  Rage Against The Time
//

import UserNotifications

final class NotificationManager {
    static let shared = NotificationManager()
    private init() {}

    private let doneID = "timer_done"
    private let warningID = "timer_warning"

    /// Beder om tilladelse. Er svaret allerede givet, sker der ingenting.
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                print("⚠️ Notifikationer: \(error.localizedDescription)")
            } else {
                print(granted ? "✅ Notifikationer tilladt" : "❌ Notifikationer afvist")
            }
        }
    }

    /// Planlægger "tiden er gået" og evt. en advarsel. Erstatter alt tidligere planlagt.
    func scheduleTimerNotifications(secondsToEnd: Int, warningSeconds: Int) {
        cancelTimerNotifications()          // altid først, også hvis vi ikke planlægger noget nyt
        guard secondsToEnd > 0 else { return }

        schedule(id: doneID,
                 title: "Rage Against The Time ⌛️",
                 body: "Tiden er gået!",
                 after: secondsToEnd)

        if warningSeconds > 0 && secondsToEnd > warningSeconds {
            let minutes = max(1, warningSeconds / 60)
            schedule(id: warningID,
                     title: "Rage Against The Time ⏱️",
                     body: "Der er kun \(minutes) min. tilbage!",
                     after: secondsToEnd - warningSeconds)
        }
    }

    func cancelTimerNotifications() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [doneID, warningID])
    }

    private func schedule(id: String, title: String, body: String, after seconds: Int) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // Bryder igennem Fokus. Kræver capability "Time Sensitive Notifications", men ingen godkendelse fra Apple.
        content.interruptionLevel = .timeSensitive

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(seconds), repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { print("⚠️ Kunne ikke planlægge notifikation: \(error.localizedDescription)") }
        }
    }
}
