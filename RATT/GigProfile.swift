//
//  GigProfile.swift
//  Rage Against The Time
//
//  Gig-profiler: gemte sæt indstillinger (fx "Klub 45 min", "Festival 21:00–21:45"),
//  som sendes til pedalen med ét tryk. Profilerne gemmes på telefonen i UserDefaults.
//
//  Tidsplan (kun nedtælling):
//   - Sluttidspunkt: pedalen tæller ned til klokkeslættet i stedet for en fast varighed.
//   - Starttidspunkt: pedalen starter timeren af sig selv (kræver firmware 2.2, "startat").
//

import SwiftUI

// MARK: - Model

struct GigProfile: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var mode: String = "countdown"          // countdown | countup | stopwatch
    var durationSeconds: Int = 1800
    var warningMinutes: Int = 0
    var underRun: Bool = false
    var maxUnderRunMinutes: Int = 5
    var ledEscalation: Bool = true
    var clockAlwaysOn: Bool = true
    var brightness1: Int = 7                // 0-7 (uret)
    var brightness2: Int = 7                // 0-7 (timeren)
    var ledBrightness: Int = 50             // 0-100
    var endMinutes: Int? = nil              // sluttidspunkt, minutter siden midnat
    var startMinutes: Int? = nil            // starttidspunkt (auto-start), kræver sluttidspunkt

    enum CodingKeys: String, CodingKey {
        case id, name, mode, durationSeconds, warningMinutes, underRun, maxUnderRunMinutes
        case ledEscalation, clockAlwaysOn, brightness1, brightness2, ledBrightness
        case endMinutes, startMinutes
    }
}

// Tolerant indlæsning: manglende felter (fra ældre gemte profiler) får standardværdier
extension GigProfile {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Profil"
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "countdown"
        durationSeconds = try c.decodeIfPresent(Int.self, forKey: .durationSeconds) ?? 1800
        warningMinutes = try c.decodeIfPresent(Int.self, forKey: .warningMinutes) ?? 0
        underRun = try c.decodeIfPresent(Bool.self, forKey: .underRun) ?? false
        maxUnderRunMinutes = try c.decodeIfPresent(Int.self, forKey: .maxUnderRunMinutes) ?? 5
        ledEscalation = try c.decodeIfPresent(Bool.self, forKey: .ledEscalation) ?? true
        clockAlwaysOn = try c.decodeIfPresent(Bool.self, forKey: .clockAlwaysOn) ?? true
        brightness1 = try c.decodeIfPresent(Int.self, forKey: .brightness1) ?? 7
        brightness2 = try c.decodeIfPresent(Int.self, forKey: .brightness2) ?? 7
        ledBrightness = try c.decodeIfPresent(Int.self, forKey: .ledBrightness) ?? 50
        endMinutes = try c.decodeIfPresent(Int.self, forKey: .endMinutes)
        startMinutes = try c.decodeIfPresent(Int.self, forKey: .startMinutes)
    }
}

// MARK: - Afledte værdier

extension GigProfile {

    static let modeNames = [
        "countdown": "Nedtælling",
        "countup": "Optælling",
        "stopwatch": "Stopur"
    ]

    // Værdier der faktisk giver mening for den valgte tilstand
    var effectiveWarning: Int { mode == "stopwatch" ? 0 : warningMinutes }
    var effectiveUnderRun: Bool { mode == "countdown" && underRun }

    /// Tidsplanen gælder kun for nedtælling
    var scheduleEnd: Int? { mode == "countdown" ? endMinutes : nil }
    var scheduleStart: Int? { scheduleEnd != nil ? startMinutes : nil }

    var summary: String {
        var parts: [String] = [Self.modeNames[mode] ?? mode]

        if let end = scheduleEnd {
            if let start = scheduleStart {
                parts.append("kl. \(Self.clockText(minutes: start))–\(Self.clockText(minutes: end)), starter automatisk")
            } else {
                parts.append("slut kl. \(Self.clockText(minutes: end))")
            }
        } else if mode != "stopwatch" {
            parts.append(Self.durationText(durationSeconds))
        }

        if effectiveWarning > 0 { parts.append("advarsel \(effectiveWarning) min") }
        if effectiveUnderRun { parts.append("under-run \(maxUnderRunMinutes) min") }
        return parts.joined(separator: " · ")
    }

    static func durationText(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        if h > 0 && m > 0 { return "\(h)t \(m)m" }
        if h > 0 { return "\(h)t" }
        return "\(m) min"
    }

    // MARK: Klokkeslæt-hjælpere

    static func clockText(minutes: Int) -> String {
        String(format: "%02d:%02d", (minutes / 60) % 24, minutes % 60)
    }

    static func secondsOfDay(_ date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        return (c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60 + (c.second ?? 0)
    }

    static func minutesOfDay(_ date: Date) -> Int {
        secondsOfDay(date) / 60
    }

    static func hms(_ date: Date) -> String {
        let s = secondsOfDay(date)
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}

// MARK: - Kommandoer til pedalen

struct ApplyPlan {
    var commands: [String]
    var warnings: [String]
}

extension GigProfile {

    /// Grundindstillinger. "mode" kommer først, fordi den nulstiller timeren, og "duration" bagefter.
    /// Varigheden sendes også ved sluttidspunkt, så den kan bruges som reserve, hvis timeren nulstilles.
    var baseCommands: [String] {
        var list = ["mode:\(mode)"]
        if mode != "stopwatch" { list.append("duration:\(durationSeconds)") }
        list += [
            "warning:\(effectiveWarning)",
            "underrun:\(effectiveUnderRun ? "on" : "off")",
            "maxunderrun:\(maxUnderRunMinutes)",
            "ledesc:\(ledEscalation ? "on" : "off")",
            "clockalways:\(clockAlwaysOn ? "on" : "off")",
            "brightness1:\(brightness1)",
            "brightness2:\(brightness2)",
            "ledbrightness:\(ledBrightness)"
        ]
        return list
    }

    /// Kommandoer + advarsler. Tidsplanen afhænger af klokken lige nu:
    ///  - er slottet allerede i gang, startes timeren med det samme (og slutter på sluttidspunktet),
    ///  - ligger starten frem i tiden, sætter pedalen selv timeren i gang på det tidspunkt,
    ///  - er sluttidspunktet passeret eller mere end 9t 59m væk, sættes timeren uden tidsplan.
    func plan(now: Date = Date()) -> ApplyPlan {
        var commands = baseCommands
        var warnings: [String] = []

        guard let endMin = scheduleEnd else {
            return ApplyPlan(commands: commands, warnings: warnings)
        }

        let limit = 35_999                         // pedalens display kan vise op til 9t 59m 59s
        let nowSecs = Self.secondsOfDay(now)
        let endSecs = endMin * 60
        let untilEnd = (endSecs - nowSecs + 86_400) % 86_400

        guard (1...limit).contains(untilEnd) else {
            warnings.append("Sluttidspunktet kl. \(Self.clockText(minutes: endMin)) er passeret eller ligger mere end 9t 59m ude i fremtiden. Timeren er sat med varigheden i stedet.")
            return ApplyPlan(commands: commands, warnings: warnings)
        }

        // Klokken sendes først, så pedalen regner ud fra samme tid som telefonen
        commands.append("time:\(Self.hms(now))")
        commands.append("endat:\(Self.clockText(minutes: endMin)):00")

        if let startMin = scheduleStart {
            let startSecs = startMin * 60
            let slot = (endSecs - startSecs + 86_400) % 86_400
            let elapsed = (nowSecs - startSecs + 86_400) % 86_400

            if slot > 0 && elapsed < slot {
                commands.append("start")           // slottet er allerede begyndt
            } else if slot > 0 {
                let untilStart = (startSecs - nowSecs + 86_400) % 86_400
                if (1...limit).contains(untilStart) {
                    commands.append("startat:\(Self.clockText(minutes: startMin)):00")
                } else {
                    warnings.append("Starttidspunktet kl. \(Self.clockText(minutes: startMin)) ligger mere end 9t 59m ude i fremtiden. Start timeren selv.")
                }
            }
        }

        return ApplyPlan(commands: commands, warnings: warnings)
    }

    // MARK: Matching og oprettelse

    /// Passer pedalens nuværende indstillinger til profilen? Bruges til at vise, hvilken profil der er aktiv.
    func matches(_ b: BluetoothManager) -> Bool {
        guard b.isConnected, b.hasReceivedStatus, b.timerMode == mode else { return false }

        if mode != "stopwatch" {
            if let endMin = scheduleEnd {
                // Pedalen kender ikke sluttidspunktet direkte, men kan regnes ud fra resttiden (±1 min)
                guard b.endAtActive else { return false }
                let pedalEnd = Self.minutesOfDay(Date().addingTimeInterval(TimeInterval(b.remainingSeconds) + 30))
                let diff = abs(pedalEnd - endMin)
                guard min(diff, 1440 - diff) <= 1 else { return false }
            } else {
                guard !b.endAtActive, b.durationSeconds == durationSeconds else { return false }
            }
        }

        guard b.warningTime == effectiveWarning, b.underRunEnabled == effectiveUnderRun else { return false }
        if effectiveUnderRun && b.maxUnderRunMinutes != maxUnderRunMinutes { return false }

        return b.ledEscalation == ledEscalation
            && b.clockAlwaysOn == clockAlwaysOn
            && b.brightness1 == brightness1
            && b.brightness2 == brightness2
            && b.ledBrightness == ledBrightness
    }

    /// Ny profil ud fra pedalens nuværende indstillinger ("gem det jeg har nu").
    static func current(from b: BluetoothManager, name: String = "") -> GigProfile {
        var profile = GigProfile(
            name: name,
            mode: b.timerMode,
            durationSeconds: b.endAtActive ? 1800 : max(60, b.durationSeconds),
            warningMinutes: b.warningTime,
            underRun: b.underRunEnabled,
            maxUnderRunMinutes: b.maxUnderRunMinutes,
            ledEscalation: b.ledEscalation,
            clockAlwaysOn: b.clockAlwaysOn,
            brightness1: b.brightness1,
            brightness2: b.brightness2,
            ledBrightness: b.ledBrightness
        )
        // Er der et sluttidspunkt i gang, tages det med (rundet til nærmeste minut)
        if b.endAtActive && b.timerMode == "countdown" {
            profile.endMinutes = minutesOfDay(Date().addingTimeInterval(TimeInterval(b.remainingSeconds) + 30))
        }
        return profile
    }

    /// Eksempler ved første start. Kan slettes eller ændres frit.
    static var samples: [GigProfile] {
        [
            GigProfile(name: "Klub 45 min", durationSeconds: 45 * 60, warningMinutes: 5),
            GigProfile(name: "Festival 30 min", durationSeconds: 30 * 60, warningMinutes: 3),
            GigProfile(name: "Øvning", mode: "stopwatch", durationSeconds: 1800)
        ]
    }
}

// MARK: - Lager

final class ProfileStore: ObservableObject {
    @Published var profiles: [GigProfile] {
        didSet { save() }
    }

    private let key = "gigProfiles.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([GigProfile].self, from: data) {
            profiles = decoded
        } else {
            profiles = GigProfile.samples
            save()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func upsert(_ profile: GigProfile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
    }

    func delete(at offsets: IndexSet) {
        profiles.remove(atOffsets: offsets)
    }

    func move(from source: IndexSet, to destination: Int) {
        profiles.move(fromOffsets: source, toOffset: destination)
    }

    /// Sender profilens indstillinger til pedalen og returnerer eventuelle advarsler.
    /// Kommandoerne sendes med lidt luft imellem, så pedalens kommandokø (8 pladser) ikke løber fuld.
    @discardableResult
    func apply(_ profile: GigProfile, to bluetooth: BluetoothManager) -> [String] {
        let plan = profile.plan()
        for (index, command) in plan.commands.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08 * Double(index)) {
                bluetooth.sendCommand(command)
            }
        }
        return plan.warnings
    }
}
