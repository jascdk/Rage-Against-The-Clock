//
//  BluetoothManager.swift
//  Rage Against The Time
//
//  Protokol v2.3 (matcher RageAgainstTheTime.ino)
//   0101 COMMAND  write            "action:value"
//   0102 STATUS   read + notify    {"r":1,"t":1234,"d":0}
//   0103 CONFIG   read + notify    se parseConfig()
//

import Foundation
import CoreBluetooth

final class BluetoothManager: NSObject, ObservableObject {

    enum ConnectionState: Equatable {
        case notStarted      // Bluetooth er ikke startet endnu (onboarding)
        case bluetoothOff
        case unauthorized
        case unsupported
        case searching       // leder efter / venter på pedalen
        case connecting      // forbundet, henter services
        case connected       // klar til brug
    }

    // MARK: - Publiceret tilstand

    @Published private(set) var connectionState: ConnectionState = .notStarted
    @Published private(set) var hasReceivedStatus = false

    // Hurtig status
    @Published private(set) var remainingSeconds = 0
    @Published private(set) var isTimerRunning = false
    @Published private(set) var isTimerDone = false

    // Config
    @Published private(set) var timerMode = "countdown"
    @Published private(set) var durationSeconds = 1800     // effektiv varighed (ved slut-klokkeslot: samlet tid)
    @Published private(set) var endAtActive = false        // tæller ned til et klokkeslot
    @Published private(set) var startAtActive = false      // pedalen starter timeren automatisk
    @Published private(set) var brightness1 = 7            // 0-7 (uret)
    @Published private(set) var brightness2 = 7            // 0-7 (timeren)
    @Published private(set) var ledBrightness = 50         // 0-100
    @Published private(set) var ledEscalation = true       // LED skifter farve mod slut
    @Published private(set) var warningTime = 0
    @Published private(set) var underRunEnabled = false
    @Published private(set) var maxUnderRunMinutes = 5
    @Published private(set) var displayFlipped = false
    @Published private(set) var clockAlwaysOn = true
    @Published private(set) var swapDisplays = false
    @Published private(set) var screensaverEnabled = true
    @Published private(set) var screensaverMinutes = 2

    var isConnected: Bool { connectionState == .connected }

    /// Firmwareopdatering over Bluetooth (OTA)
    let firmware = FirmwareUpdater()

    // MARK: - BLE

    private let serviceUUID = CBUUID(string: "6f8d0100-2b44-4c1c-a7f9-7d9d2f734301")
    private let commandUUID = CBUUID(string: "6f8d0101-2b44-4c1c-a7f9-7d9d2f734301")
    private let statusUUID  = CBUUID(string: "6f8d0102-2b44-4c1c-a7f9-7d9d2f734301")
    private let configUUID  = CBUUID(string: "6f8d0103-2b44-4c1c-a7f9-7d9d2f734301")
    private let otaDataUUID   = CBUUID(string: "6f8d0104-2b44-4c1c-a7f9-7d9d2f734301")
    private let otaStatusUUID = CBUUID(string: "6f8d0105-2b44-4c1c-a7f9-7d9d2f734301")

    private let savedDeviceKey = "savedPedalIdentifier"
    private let restoreID = "com.ratt.central"
    private let clockSyncInterval: TimeInterval = 300

    private var central: CBCentralManager?
    private var pedal: CBPeripheral?
    private var commandChar: CBCharacteristic?
    private var statusChar: CBCharacteristic?
    private var configChar: CBCharacteristic?
    private var otaDataChar: CBCharacteristic?
    private var otaStatusChar: CBCharacteristic?
    private var handshakeDone = false
    private var hasFast = false
    private var hasConfig = false
    private var clockTimer: Timer?

    // Notifikationer
    private var notificationsArmed = false
    private var armedSignature = ""
    private var forceNotificationReconcile = true

    override init() {
        super.init()
        firmware.transport = self
        firmware.onVersionChange = { [weak self] in self?.objectWillChange.send() }
        // Er onboarding gennemført, startes Bluetooth med det samme (også ved state restoration)
        if UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            start()
        }
    }

    // MARK: - Offentlig API

    /// Starter Bluetooth. Kaldes først efter onboarding, så permission-prompten kommer på det rigtige tidspunkt.
    func start() {
        guard central == nil else { return }
        central = CBCentralManager(
            delegate: self,
            queue: nil,   // main queue, så callbacks kan opdatere UI direkte
            options: [CBCentralManagerOptionRestoreIdentifierKey: restoreID]
        )
    }

    func appDidBecomeActive() {
        guard central != nil else { return }
        LiveActivityManager.shared.invalidate()   // giver mulighed for at starte en Live Activity i forgrunden
        if isConnected {
            if let p = pedal, let s = statusChar, let c = configChar {
                p.readValue(for: s)
                p.readValue(for: c)
            }
            sendCurrentTime()
        } else {
            beginConnection()
        }
    }

    func sendCommand(_ command: String) {
        guard isConnected,
              let p = pedal,
              let c = commandChar,
              let data = command.data(using: .utf8) else { return }
        p.writeValue(data, for: c, type: .withResponse)
    }

    /// Tæl ned til et klokkeslot (næste forekomst). Kald kun med en gyldig tid, dvs. højst 9t 59m ude i fremtiden.
    /// Klokken sendes først, så pedalen regner ud fra samme tid som telefonen.
    func setEndTime(hour: Int, minute: Int, startNow: Bool) {
        sendCurrentTime()
        sendCommand(String(format: "endat:%02d:%02d:00", hour, minute))
        if startNow { sendCommand("start") }
    }

    /// Glem den gemte pedal og led efter en ny.
    func forgetDevice() {
        UserDefaults.standard.removeObject(forKey: savedDeviceKey)
        stopClockSync()
        if let p = pedal { central?.cancelPeripheralConnection(p) }
        central?.stopScan()
        pedal = nil
        resetLinkState()
        beginConnection()
    }

    // MARK: - Forbindelse

    private func beginConnection() {
        guard let central, central.state == .poweredOn else { return }

        if let p = pedal {
            switch p.state {
            case .connected:
                connectionState = .connecting
                p.discoverServices([serviceUUID])
            case .disconnected:
                connectionState = .searching
                central.connect(p, options: nil)      // pending connect uden timeout
            default:
                break
            }
            return
        }

        if let idString = UserDefaults.standard.string(forKey: savedDeviceKey),
           let uuid = UUID(uuidString: idString),
           let known = central.retrievePeripherals(withIdentifiers: [uuid]).first {
            adopt(known)
            connectionState = .searching
            central.connect(known, options: nil)
            return
        }

        connectionState = .searching
        central.scanForPeripherals(withServices: [serviceUUID], options: nil)
    }

    private func adopt(_ p: CBPeripheral) {
        pedal = p
        p.delegate = self
    }

    private func resetLinkState() {
        commandChar = nil
        statusChar = nil
        configChar = nil
        otaDataChar = nil
        otaStatusChar = nil
        handshakeDone = false
        hasFast = false
        hasConfig = false
    }

    // MARK: - Ur-sync

    private func startClockSync() {
        stopClockSync()
        sendCurrentTime()
        clockTimer = Timer.scheduledTimer(withTimeInterval: clockSyncInterval, repeats: true) { [weak self] _ in
            self?.sendCurrentTime()
        }
    }

    private func stopClockSync() {
        clockTimer?.invalidate()
        clockTimer = nil
    }

    private func sendCurrentTime() {
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: Date())
        sendCommand(String(format: "time:%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0))
    }

    // MARK: - Parsing

    private func update<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<BluetoothManager, T>, _ value: T) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    private func parseStatus(_ data: Data) {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            print("⚠️ Status-JSON kunne ikke læses (\(data.count) bytes)")
            return
        }
        if let r = json["r"] as? Int { update(\.isTimerRunning, r == 1) }
        if let t = json["t"] as? Int { update(\.remainingSeconds, t) }
        if let d = json["d"] as? Int { update(\.isTimerDone, d == 1) }
        hasFast = true
        update(\.hasReceivedStatus, true)
        reconcileNotifications()
        reconcileLiveActivity()
    }

    private func parseConfig(_ data: Data) {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            print("⚠️ Config-JSON kunne ikke læses (\(data.count) bytes)")
            return
        }
        if let v = json["mode"] as? String { update(\.timerMode, v) }
        if let v = json["dur"] as? Int { update(\.durationSeconds, v) }
        if let v = json["ea"] as? Int { update(\.endAtActive, v == 1) }
        if let v = json["sa"] as? Int { update(\.startAtActive, v == 1) }
        if let v = json["b1"] as? Int { update(\.brightness1, v) }
        if let v = json["b2"] as? Int { update(\.brightness2, v) }
        if let v = json["led"] as? Int { update(\.ledBrightness, v) }
        if let v = json["esc"] as? Int { update(\.ledEscalation, v == 1) }
        if let v = json["warn"] as? Int { update(\.warningTime, v) }
        if let v = json["ur"] as? Int { update(\.underRunEnabled, v == 1) }
        if let v = json["mur"] as? Int { update(\.maxUnderRunMinutes, v) }
        if let v = json["flip"] as? Int { update(\.displayFlipped, v == 1) }
        if let v = json["clk"] as? Int { update(\.clockAlwaysOn, v == 1) }
        if let v = json["swap"] as? Int { update(\.swapDisplays, v == 1) }
        if let v = json["scr"] as? Int { update(\.screensaverEnabled, v == 1) }
        if let v = json["scrm"] as? Int { update(\.screensaverMinutes, v) }
        if let v = json["ts"] as? Int, v == 0 { sendCurrentTime() }   // pedalen kender ikke klokken
        hasConfig = true
        reconcileNotifications()
        reconcileLiveActivity()
    }

    // MARK: - Notifikationer (følger pedalens tilstand, ikke app-knapperne)

    private func reconcileNotifications() {
        guard hasFast, hasConfig else { return }

        let armable = isTimerRunning && timerMode != "stopwatch"
        let signature = "\(timerMode)|\(durationSeconds)|\(warningTime)"

        if armable {
            if forceNotificationReconcile || !notificationsArmed || signature != armedSignature {
                let isCountdown = (timerMode == "countdown")
                let secondsToEnd = isCountdown ? remainingSeconds : durationSeconds - remainingSeconds
                let warnSeconds = isCountdown ? warningTime * 60 : 0
                NotificationManager.shared.scheduleTimerNotifications(secondsToEnd: secondsToEnd,
                                                                      warningSeconds: warnSeconds)
                notificationsArmed = true
                armedSignature = signature
            }
        } else if !isTimerDone && (notificationsArmed || forceNotificationReconcile) {
            // Ved done lader vi den planlagte notifikation fyre selv (ellers kan en hurtig
            // BLE-besked annullere den millisekunder før den skulle have lydt).
            NotificationManager.shared.cancelTimerNotifications()
            notificationsArmed = false
        }
        forceNotificationReconcile = false
    }

    // MARK: - Live Activity

    private func reconcileLiveActivity() {
        guard hasFast, hasConfig else { return }
        LiveActivityManager.shared.update(
            mode: timerMode,
            isRunning: isTimerRunning,
            isDone: isTimerDone,
            isConnected: true,
            underRun: underRunEnabled,
            remaining: remainingSeconds,
            duration: durationSeconds
        )
    }
}

// MARK: - CBCentralManagerDelegate

extension BluetoothManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            beginConnection()
        case .poweredOff:
            stopClockSync()
            resetLinkState()
            pedal = nil
            connectionState = .bluetoothOff
            firmware.linkLost()
            LiveActivityManager.shared.markDisconnected()
        case .unauthorized:
            connectionState = .unauthorized
        case .unsupported:
            connectionState = .unsupported
        default:
            break   // .unknown / .resetting
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let p = restored.first {
            adopt(p)
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover found: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        guard pedal == nil else { return }
        if let saved = UserDefaults.standard.string(forKey: savedDeviceKey),
           saved != found.identifier.uuidString { return }   // kun den pedal vi kender
        central.stopScan()
        adopt(found)
        connectionState = .searching
        central.connect(found, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect connected: CBPeripheral) {
        guard connected === pedal else { return }
        UserDefaults.standard.set(connected.identifier.uuidString, forKey: savedDeviceKey)
        connectionState = .connecting
        connected.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect failed: CBPeripheral, error: Error?) {
        guard failed === pedal else { return }
        print("⚠️ Forbindelse fejlede: \(error?.localizedDescription ?? "ukendt")")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.beginConnection()
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral gone: CBPeripheral, error: Error?) {
        guard gone === pedal else { return }   // ignorerer en pedal vi har glemt
        stopClockSync()
        resetLinkState()
        connectionState = .searching
        firmware.linkLost()
        LiveActivityManager.shared.markDisconnected()
        central.connect(gone, options: nil)    // iOS genforbinder, så snart pedalen er i nærheden igen
    }
}

// MARK: - CBPeripheralDelegate

extension BluetoothManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { print("⚠️ Service discovery: \(error.localizedDescription)"); return }
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else { return }
        peripheral.discoverCharacteristics([commandUUID, statusUUID, configUUID, otaDataUUID, otaStatusUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { print("⚠️ Characteristic discovery: \(error.localizedDescription)"); return }
        for c in service.characteristics ?? [] {
            switch c.uuid {
            case commandUUID: commandChar = c
            case statusUUID:  statusChar = c
            case configUUID:  configChar = c
            case otaDataUUID: otaDataChar = c
            case otaStatusUUID: otaStatusChar = c
            default: break
            }
        }
        guard !handshakeDone, let s = statusChar, let cfg = configChar, commandChar != nil else { return }

        handshakeDone = true
        peripheral.setNotifyValue(true, for: s)
        peripheral.setNotifyValue(true, for: cfg)
        peripheral.readValue(for: s)      // hent starttilstand med det samme
        peripheral.readValue(for: cfg)
        firmware.setSupported(otaDataChar != nil && otaStatusChar != nil)
        if let ota = otaStatusChar {
            peripheral.setNotifyValue(true, for: ota)
            peripheral.readValue(for: ota)        // version, OTA-plads og oppetid
        }
        forceNotificationReconcile = true
        connectionState = .connected
        startClockSync()                  // nu findes command-characteristic, så første sync går igennem
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { print("⚠️ Læsefejl: \(error.localizedDescription)"); return }
        guard let data = characteristic.value else { return }
        switch characteristic.uuid {
        case statusUUID: parseStatus(data)
        case configUUID: parseConfig(data)
        case otaStatusUUID: firmware.handleStatus(data)
        default: break
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        firmware.transportReady()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { print("⚠️ Skrivefejl: \(error.localizedDescription)") }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error { print("⚠️ Notify-fejl: \(error.localizedDescription)") }
    }
}

// MARK: - FirmwareTransport (bruges af FirmwareUpdater)

extension BluetoothManager: FirmwareTransport {

    /// Største pakke uden svar. Pedalens buffer rummer 184 bytes pr. pakke.
    var otaChunkSize: Int {
        guard let p = pedal else { return 0 }
        return min(p.maximumWriteValueLength(for: .withoutResponse), 182)
    }

    var canSendOtaData: Bool {
        pedal?.canSendWriteWithoutResponse ?? false
    }

    func sendOtaCommand(_ command: String) {
        sendCommand(command)
    }

    func sendOtaData(_ data: Data) {
        guard let p = pedal, let c = otaDataChar else { return }
        p.writeValue(data, for: c, type: .withoutResponse)
    }
}
