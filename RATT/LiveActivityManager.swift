//
//  LiveActivityManager.swift
//  Rage Against The Time
//
//  DEBUG-version med log-linjer (🟣 LA:). Kun app-target.
//  Timeren tælles af systemet via Text(timerInterval:), så vi behøver kun at
//  opdatere ved tilstandsskift (start, pause, nulstil, færdig, forbindelsestab).
//
//  Bemærk: iOS tillader kun at STARTE en Live Activity, mens appen er i forgrunden.
//

import ActivityKit
import Foundation

final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private typealias State = TimerActivityAttributes.ContentState

    private var activity: Activity<TimerActivityAttributes>?
    private var lastSignature = ""
    private var lastState: State?

    private init() {
        // Overtag en aktivitet fra en tidligere app-session
        activity = Activity<TimerActivityAttributes>.activities.first
        log("init, eksisterende aktivitet: \(activity != nil)")
    }

    private func log(_ message: String) {
        print("🟣 LA: \(message)")
    }

    /// Tving en ny opdatering ved næste status (fx når appen kommer i forgrunden).
    func invalidate() {
        lastSignature = ""
    }

    func update(mode: String,
                isRunning: Bool,
                isDone: Bool,
                isConnected: Bool,
                underRun: Bool,
                remaining: Int,
                duration: Int) {
        let info = ActivityAuthorizationInfo()
        guard info.areActivitiesEnabled else {
            log("STOP: Live Activities er slået fra på telefonen (Indstillinger → Rage Against The Time → Live aktiviteter)")
            return
        }

        // Brugeren kan have fjernet aktiviteten manuelt
        if let a = activity, a.activityState == .ended || a.activityState == .dismissed {
            log("aktiviteten er afsluttet/fjernet, nulstiller")
            activity = nil
        }

        let isIdle = !isRunning && !isDone &&
            ((mode == "countdown" && remaining == duration) || (mode != "countdown" && remaining == 0))

        // Under kørsel ændrer remaining sig hvert sekund, men det er ikke en ny tilstand
        let signature = "\(mode)|\(isRunning)|\(isDone)|\(isConnected)|\(underRun)|\(duration)|\(isRunning ? 0 : remaining)"
        guard signature != lastSignature else { return }
        lastSignature = signature

        log("ny tilstand: mode=\(mode) running=\(isRunning) done=\(isDone) idle=\(isIdle) remaining=\(remaining) duration=\(duration) harAktivitet=\(activity != nil)")

        if isIdle {
            log("idle → afslutter aktivitet (hvis der er en)")
            end(with: nil, policy: .immediate)
            return
        }

        let state = makeState(mode: mode, isRunning: isRunning, isDone: isDone, isConnected: isConnected,
                              underRun: underRun, remaining: remaining, duration: duration)
        lastState = state

        if isDone {
            // Vis færdig-tilstanden et øjeblik og fjern den så
            if activity != nil {
                log("done → afslutter aktivitet om 90 sek.")
                end(with: ActivityContent(state: state, staleDate: nil),
                    policy: .after(Date().addingTimeInterval(90)))
            } else {
                log("done, men ingen aktivitet at afslutte")
            }
            return
        }

        let content = ActivityContent(state: state, staleDate: staleDate(for: state))

        if let current = activity {
            log("opdaterer eksisterende aktivitet")
            Task { await current.update(content) }
        } else if isRunning && isConnected {
            log("forsøger at starte ny aktivitet...")
            do {
                activity = try Activity.request(
                    attributes: TimerActivityAttributes(name: "Rage Against The Time"),
                    content: content,
                    pushType: nil
                )
                log("✅ aktivitet startet, id=\(activity?.id ?? "?")")
            } catch {
                log("❌ kunne ikke starte: \(error)")
                lastSignature = ""   // prøv igen næste gang appen er i forgrunden
            }
        } else {
            log("starter ikke: kræver running=true og connected=true (running=\(isRunning), connected=\(isConnected))")
        }
    }

    /// Pedalen er ude af rækkevidde: vis det tydeligt i stedet for et tal, der ser rigtigt ud.
    func markDisconnected() {
        lastSignature = ""
        guard var state = lastState, let current = activity else { return }
        log("forbindelse tabt → opdaterer aktivitet")
        state.isConnected = false
        lastState = state
        Task { await current.update(ActivityContent(state: state, staleDate: nil)) }
    }

    // MARK: - Hjælpere

    private func end(with content: ActivityContent<State>?, policy: ActivityUIDismissalPolicy) {
        guard let current = activity else { return }
        activity = nil
        Task { await current.end(content, dismissalPolicy: policy) }
    }

    private func makeState(mode: String,
                           isRunning: Bool,
                           isDone: Bool,
                           isConnected: Bool,
                           underRun: Bool,
                           remaining: Int,
                           duration: Int) -> State {
        let now = Date()
        let start: Date
        let end: Date

        switch mode {
        case "countdown":
            end = now.addingTimeInterval(TimeInterval(remaining))
            start = end.addingTimeInterval(-TimeInterval(max(duration, remaining, 1)))
        case "countup":
            start = now.addingTimeInterval(-TimeInterval(remaining))
            end = start.addingTimeInterval(TimeInterval(max(duration, 1)))
        default: // stopwatch
            start = now.addingTimeInterval(-TimeInterval(remaining))
            end = start.addingTimeInterval(36_000)
        }

        return State(mode: mode, isRunning: isRunning, isDone: isDone, isConnected: isConnected,
                     underRun: underRun, remainingSeconds: remaining, durationSeconds: duration,
                     startDate: start, endDate: end)
    }

    /// Når tiden er gået, markeres aktiviteten "stale", og widget'en viser TIDEN ER GÅET / OVER TID,
    /// selv hvis appen ikke når at opdatere.
    private func staleDate(for state: State) -> Date? {
        guard state.isRunning, state.mode != "stopwatch" else { return nil }
        return state.endDate
    }
}
