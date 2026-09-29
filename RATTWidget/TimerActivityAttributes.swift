//
//  TimerActivityAttributes.swift
//  Rage Against The Time
//
//  Ligger som identiske kopier i både app-mappen og widget-mappen. Ret altid begge ens.
//

import ActivityKit
import Foundation

struct TimerActivityAttributes: ActivityAttributes {

    struct ContentState: Codable, Hashable {
        var mode: String            // "countdown" | "countup" | "stopwatch"
        var isRunning: Bool
        var isDone: Bool
        var isConnected: Bool
        var underRun: Bool
        var remainingSeconds: Int   // værdi ved opdateringstidspunktet (bruges når timeren står stille)
        var durationSeconds: Int
        var startDate: Date         // countdown: endDate - varighed | countup/stopur: starttidspunkt
        var endDate: Date           // countdown: sluttidspunkt | countup: start + varighed
    }

    var name: String
}
