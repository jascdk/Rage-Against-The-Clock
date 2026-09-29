//
//  RATTLiveActivity.swift
//  RATTWidget (widget extension)
//
//  Erstatter de genererede widget-filer i extension-targetet.
//  TimerActivityAttributes.swift skal også have membership i dette target.
//

import ActivityKit
import SwiftUI
import WidgetKit

@main
struct RATTWidgetBundle: WidgetBundle {
    var body: some Widget {
        RATTLiveActivity()
    }
}

struct RATTLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TimerActivityAttributes.self) { context in
            LockScreenView(state: context.state, isStale: context.isStale)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(LiveStyle.statusText(context.state, isStale: context.isStale))
                        .font(.system(size: 10, weight: .heavy, design: .monospaced))
                        .foregroundStyle(LiveStyle.tint(context.state, isStale: context.isStale))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(LiveStyle.modeText(context.state.mode))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.center) {
                    TimerReadout(state: context.state, isStale: context.isStale)
                        .font(.system(size: 40, weight: .black, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(context.state.isDone ? Color.red : Color.white)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    TimerProgress(state: context.state, isStale: context.isStale)
                        .tint(LiveStyle.tint(context.state, isStale: context.isStale))
                }
            } compactLeading: {
                Image(systemName: "timer")
                    .foregroundStyle(LiveStyle.tint(context.state, isStale: context.isStale))
            } compactTrailing: {
                TimerReadout(state: context.state, isStale: context.isStale)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .frame(width: 52)
            } minimal: {
                Image(systemName: "timer")
                    .foregroundStyle(LiveStyle.tint(context.state, isStale: context.isStale))
            }
            .keylineTint(LiveStyle.tint(context.state, isStale: context.isStale))
        }
    }
}

// MARK: - Låseskærm

private struct LockScreenView: View {
    let state: TimerActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        let tint = LiveStyle.tint(state, isStale: isStale)

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(LiveStyle.statusText(state, isStale: isStale), systemImage: "timer")
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundStyle(tint)
                Spacer()
                Text(LiveStyle.modeText(state.mode))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            TimerReadout(state: state, isStale: isStale)
                .font(.system(size: 46, weight: .black, design: .rounded))
                .monospacedDigit()
                .multilineTextAlignment(.leading)
                .foregroundStyle(state.isDone ? Color.red : Color.white)
                .frame(maxWidth: .infinity, alignment: .leading)

            TimerProgress(state: state, isStale: isStale)
                .tint(tint)
        }
        .padding(16)
    }
}

// MARK: - Selve tiden

/// Kørende tid vises med Text(timerInterval:), som systemet opdaterer uden at appen er i gang.
private struct TimerReadout: View {
    let state: TimerActivityAttributes.ContentState
    let isStale: Bool

    private var showsHours: Bool {
        state.durationSeconds >= 3600 || abs(state.remainingSeconds) >= 3600
    }

    // ClosedRange crasher, hvis lower > upper, så rækkefølgen sikres her
    private var safeRange: ClosedRange<Date> {
        min(state.startDate, state.endDate)...max(state.startDate, state.endDate)
    }

    var body: some View {
        if !state.isConnected {
            Text("--:--")
        } else if state.isDone {
            Text("DONE")
        } else if state.isRunning {
            running
        } else {
            Text(LiveStyle.formatted(state.remainingSeconds))
        }
    }

    @ViewBuilder
    private var running: some View {
        if state.mode == "countdown" {
            if isStale {
                if state.underRun {
                    // Over tid: tæl op fra sluttidspunktet
                    HStack(spacing: 0) {
                        Text("-")
                        Text(timerInterval: state.endDate...state.endDate.addingTimeInterval(7200),
                             pauseTime: nil, countsDown: false, showsHours: false)
                    }
                } else {
                    Text("0:00")
                }
            } else {
                Text(timerInterval: safeRange, pauseTime: nil, countsDown: true, showsHours: showsHours)
            }
        } else {
            Text(timerInterval: safeRange, pauseTime: nil, countsDown: false, showsHours: showsHours)
        }
    }
}

// MARK: - Statuslinje

private struct TimerProgress: View {
    let state: TimerActivityAttributes.ContentState
    let isStale: Bool

    private var safeRange: ClosedRange<Date> {
        min(state.startDate, state.endDate)...max(state.startDate, state.endDate)
    }

    private var fraction: Double {
        guard state.durationSeconds > 0 else { return 0 }
        return min(1, max(0, Double(state.remainingSeconds) / Double(state.durationSeconds)))
    }

    var body: some View {
        if state.isRunning && state.isConnected && !isStale && state.mode != "stopwatch" {
            ProgressView(timerInterval: safeRange, countsDown: state.mode == "countdown") {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
        } else if state.mode == "stopwatch" {
            EmptyView()
        } else {
            ProgressView(value: fraction)
        }
    }
}

// MARK: - Fælles stil og tekst

private enum LiveStyle {
    static func tint(_ s: TimerActivityAttributes.ContentState, isStale: Bool) -> Color {
        if !s.isConnected { return .gray }
        if s.isDone { return .red }
        if s.isRunning { return isStale ? .red : .cyan }
        return .orange
    }

    static func statusText(_ s: TimerActivityAttributes.ContentState, isStale: Bool) -> String {
        if !s.isConnected { return "FORBINDELSE TABT" }
        if s.isDone { return "TIDEN ER GÅET" }
        if s.isRunning {
            if isStale { return s.underRun ? "OVER TID" : "TIDEN ER GÅET" }
            return "KØRER"
        }
        return "PAUSET"
    }

    static func modeText(_ mode: String) -> String {
        switch mode {
        case "countup":   return "OPTÆLLING"
        case "stopwatch": return "STOPUR"
        default:          return "NEDTÆLLING"
        }
    }

    static func formatted(_ totalSeconds: Int) -> String {
        let neg = totalSeconds < 0
        let absSec = abs(totalSeconds)
        let h = absSec / 3600
        let m = (absSec % 3600) / 60
        let s = absSec % 60
        let prefix = neg ? "-" : ""
        return h > 0
            ? String(format: "%@%d:%02d:%02d", prefix, h, m, s)
            : String(format: "%@%02d:%02d", prefix, m, s)
    }
}
