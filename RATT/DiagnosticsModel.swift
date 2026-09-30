//
//  DiagnosticsModel.swift
//  Rage Against The Time
//
//  Data til diagnostik-siden. Pedalen leverer temperatur, MAC, hukommelse m.m. (DIAG og INFO).
//  Appen tilføjer det, kun telefonen kan måle: signalstyrke (RSSI), svartid og forbindelsesstatistik.
//  Der læses kun, mens siden er åben (hver 2. sekund), så det belaster hverken pedalen eller strømmen.
//

import Foundation

protocol DiagnosticsTransport: AnyObject {
    var hasDiagnostics: Bool { get }         // pedalens firmware har DIAG og INFO
    var maxWriteLength: Int { get }
    var peripheralShortID: String? { get }
    func readDiagnosticValues()
    func readDeviceInfo()
    func readSignalStrength()
}

final class DiagnosticsModel: ObservableObject {

    struct Info: Equatable {
        var mac = "–"
        var chip = "–"
        var revision = 0
        var cpuMHz = 0
        var flashBytes = 0
        var sketchBytes = 0
        var partition = "–"
        var buildDate = "–"
        var firmware = "–"
    }

    struct Live: Equatable {
        var tempC = 0.0
        var uptimeSeconds = 0
        var freeHeap = 0
        var minHeap = 0
        var resetReason = "–"
        var commandsReceived = 0
        var commandsDropped = 0
        var commandsRejected = 0
    }

    // MARK: - Publiceret

    @Published private(set) var info: Info?
    @Published private(set) var live: Live?
    @Published private(set) var rssi: Int?
    @Published private(set) var rssiHistory: [Int] = []
    @Published private(set) var latencyMs: Int?
    @Published private(set) var connectedSince: Date?
    @Published private(set) var reconnects = 0
    @Published private(set) var statusPerSecond = 0.0
    @Published private(set) var lastStatusAt: Date?
    @Published private(set) var maxWriteLength = 0
    @Published private(set) var peripheralShortID: String?

    weak var transport: DiagnosticsTransport?

    var isSupported: Bool { transport?.hasDiagnostics ?? false }

    // MARK: - Intern

    private var timer: Timer?
    private var readStartedAt: Date?
    private var statusCounter = 0
    private var counterStart = Date()
    private var hadConnection = false
    private let historyLimit = 30

    // MARK: - Side åbnet / lukket

    func start() {
        stop()
        counterStart = Date()
        statusCounter = 0
        refreshStaticValues()
        transport?.readDeviceInfo()
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        refreshStaticValues()
        readStartedAt = Date()
        transport?.readDiagnosticValues()
        transport?.readSignalStrength()

        let elapsed = Date().timeIntervalSince(counterStart)
        if elapsed >= 1 {
            statusPerSecond = Double(statusCounter) / elapsed
            statusCounter = 0
            counterStart = Date()
        }
    }

    private func refreshStaticValues() {
        maxWriteLength = transport?.maxWriteLength ?? 0
        peripheralShortID = transport?.peripheralShortID
    }

    // MARK: - Fra BluetoothManager

    func linkEstablished() {
        connectedSince = Date()
        if hadConnection { reconnects += 1 }
        hadConnection = true
    }

    func linkLost() {
        connectedSince = nil
        rssi = nil
        latencyMs = nil
        live = nil
    }

    func noteStatusUpdate() {
        statusCounter += 1
        lastStatusAt = Date()
    }

    func handleRSSI(_ value: Int) {
        guard value != 127 && value < 0 else { return }       // 127 = ikke tilgængelig
        rssi = value
        rssiHistory.append(value)
        if rssiHistory.count > historyLimit { rssiHistory.removeFirst(rssiHistory.count - historyLimit) }
    }

    func handleDiag(_ data: Data) {
        if let started = readStartedAt {
            latencyMs = max(0, Int(Date().timeIntervalSince(started) * 1000))
            readStartedAt = nil
        }
        guard let j = json(data) else { return }
        live = Live(
            tempC: (j["tc"] as? Double) ?? 0,
            uptimeSeconds: (j["up"] as? Int) ?? 0,
            freeHeap: (j["hp"] as? Int) ?? 0,
            minHeap: (j["hm"] as? Int) ?? 0,
            resetReason: (j["rr"] as? String) ?? "–",
            commandsReceived: (j["cr"] as? Int) ?? 0,
            commandsDropped: (j["cd"] as? Int) ?? 0,
            commandsRejected: (j["cx"] as? Int) ?? 0
        )
    }

    func handleInfo(_ data: Data) {
        guard let j = json(data), j["mac"] != nil else { return }
        info = Info(
            mac: (j["mac"] as? String) ?? "–",
            chip: (j["ch"] as? String) ?? "–",
            revision: (j["rev"] as? Int) ?? 0,
            cpuMHz: (j["cpu"] as? Int) ?? 0,
            flashBytes: (j["fl"] as? Int) ?? 0,
            sketchBytes: (j["ss"] as? Int) ?? 0,
            partition: (j["pt"] as? String) ?? "–",
            buildDate: (j["bd"] as? String) ?? "–",
            firmware: (j["fw"] as? String) ?? "–"
        )
    }

    private func json(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - Tolkning af værdier

    /// Signalstyrke i ord
    static func signalText(_ rssi: Int) -> String {
        switch rssi {
        case (-60)...:      return "Stærkt"
        case (-75)...:      return "God"
        case (-85)...:      return "Svagt"
        default:            return "Meget svagt"
        }
    }

    /// 1-4 streger
    static func signalBars(_ rssi: Int) -> Int {
        switch rssi {
        case (-60)...: return 4
        case (-70)...: return 3
        case (-80)...: return 2
        default:       return 1
        }
    }

    /// Chip-revision: major * 100 + minor (fx 3 = v0.3, 101 = v1.1)
    static func revisionText(_ rev: Int) -> String {
        "v\(rev / 100).\(rev % 100)"
    }

    static func resetText(_ code: String) -> String {
        switch code {
        case "poweron":   return "Strøm tændt"
        case "ext":       return "Reset-knap"
        case "sw":        return "Software-genstart"
        case "panic":     return "Nedbrud (panic)"
        case "intwdt", "taskwdt", "wdt": return "Watchdog (programmet hang)"
        case "deepsleep": return "Vækket fra dvale"
        case "brownout":  return "Spændingsfald"
        default:          return "Andet"
        }
    }

    static func uptimeText(_ seconds: Int) -> String {
        let d = seconds / 86_400
        let h = (seconds % 86_400) / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if d > 0 { return "\(d) d \(h) t \(m) m" }
        if h > 0 { return "\(h) t \(m) m \(s) s" }
        return "\(m) m \(s) s"
    }

    // MARK: - Rapport til udklipsholderen

    func report(connected: Bool) -> String {
        var lines = ["RATT diagnostik", "Forbundet: \(connected ? "ja" : "nej")"]
        if let rssi { lines.append("Signal: \(rssi) dBm (\(Self.signalText(rssi)))") }
        if let latencyMs { lines.append("Svartid: \(latencyMs) ms") }
        lines.append("Genforbindelser: \(reconnects)")
        lines.append(String(format: "Statusopdateringer: %.1f pr. sekund", statusPerSecond))
        if maxWriteLength > 0 { lines.append("Største skrivepakke: \(maxWriteLength) byte") }
        if let i = info {
            lines.append("MAC: \(i.mac)")
            lines.append("Firmware: \(i.firmware), bygget \(i.buildDate)")
            lines.append("Chip: \(i.chip) \(Self.revisionText(i.revision)), \(i.cpuMHz) MHz")
            lines.append("Flash: \(i.flashBytes / 1024) KB, firmware \(i.sketchBytes / 1024) KB, partition \(i.partition)")
        }
        if let l = live {
            lines.append(String(format: "Chip-temperatur: %.1f °C", l.tempC))
            lines.append("Oppetid: \(Self.uptimeText(l.uptimeSeconds))")
            lines.append("Frit heap: \(l.freeHeap / 1024) KB (laveste \(l.minHeap / 1024) KB)")
            lines.append("Sidste nulstilling: \(Self.resetText(l.resetReason))")
            lines.append("Kommandoer: \(l.commandsReceived) modtaget, \(l.commandsDropped) tabt, \(l.commandsRejected) afvist")
        }
        return lines.joined(separator: "\n")
    }
}
