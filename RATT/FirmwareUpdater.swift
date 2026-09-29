//
//  FirmwareUpdater.swift
//  Rage Against The Time
//
//  Firmwareopdatering over Bluetooth (OTA).
//
//  Flow:  ota:begin:<bytes>  →  "ready"  →  data i pakker (write without response, 8 KB vindue)
//         →  kvittering hver 2 KB  →  ota:end  →  "done"  →  pedalen genstarter  →  appen forbinder igen
//         og læser den nye version.
//
//  Den overførte fil er den KOMPILEREDE firmware (.ino.bin), ikke .ino-kildekoden.
//

import Foundation

/// Det lag der faktisk taler med pedalen (implementeres af BluetoothManager).
protocol FirmwareTransport: AnyObject {
    var otaChunkSize: Int { get }
    var canSendOtaData: Bool { get }
    func sendOtaCommand(_ command: String)
    func sendOtaData(_ data: Data)
}

final class FirmwareUpdater: ObservableObject {

    enum Phase: Equatable {
        case idle
        case preparing          // pedalen sletter flash
        case transferring       // data sendes
        case verifying          // pedalen kontrollerer imaget
        case rebooting          // pedalen genstarter og forbinder igen
        case success
        case failed(String)
    }

    // MARK: - Enhedens oplysninger

    @Published private(set) var isSupported = false            // pedalen har OTA-characteristics
    @Published private(set) var otaPartitionAvailable = true   // partitionstabellen har plads til to versioner
    @Published private(set) var maxImageSize = 0
    @Published private(set) var deviceVersion: String? = nil {
        didSet { if oldValue != deviceVersion { onVersionChange?() } }
    }

    // MARK: - Valgt fil

    @Published private(set) var fileName: String?
    @Published private(set) var fileSize = 0
    @Published private(set) var fileError: String?

    // MARK: - Fremdrift

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var bytesAcked = 0
    @Published private(set) var speedBytesPerSecond: Double = 0
    @Published private(set) var etaSeconds: Int?
    @Published private(set) var updatedVersion: String?

    weak var transport: FirmwareTransport?
    var onVersionChange: (() -> Void)?

    var hasValidFile: Bool { image != nil }

    var isBusy: Bool {
        switch phase {
        case .preparing, .transferring, .verifying, .rebooting: return true
        default: return false
        }
    }

    // MARK: - Intern tilstand

    private var image: Data?
    private var sentOffset = 0
    private var ackedOffset = 0
    private var startedAt = Date()
    private var deadline: Date?
    private var ticker: Timer?
    private var receivedDone = false

    private let window = 8192          // bytes i luften ad gangen (pedalens kø rummer ca. 12 KB)
    private var chunkSize = 0

    private var totalBytes: Int { image?.count ?? 0 }

    // MARK: - Oplysninger fra pedalen

    func setSupported(_ value: Bool) {
        isSupported = value
        if !value { deviceVersion = nil }
    }

    func handleStatus(_ data: Data) {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }

        // Oplysninger (læses ved forbindelse): {"fw":"2.3.0","ota":1,"max":1310720,"up":12}
        if let fw = json["fw"] as? String {
            isSupported = true
            deviceVersion = fw
            otaPartitionAvailable = ((json["ota"] as? Int) ?? 1) == 1
            maxImageSize = (json["max"] as? Int) ?? 0

            // Efter en opdatering er pedalen genstartet, når oppetiden er kort
            if phase == .rebooting, let up = json["up"] as? Int, up < 120 {
                finishSuccess(version: fw)
            }
            return
        }

        // Beskeder under opdatering
        guard let state = json["s"] as? String else { return }
        switch state {
        case "ready":
            guard phase == .preparing else { return }
            phase = .transferring
            startedAt = Date()
            sentOffset = 0
            ackedOffset = 0
            deadline = Date().addingTimeInterval(25)
            pump()

        case "p":
            guard phase == .transferring, let offset = json["o"] as? Int else { return }
            if offset > ackedOffset {
                ackedOffset = offset
                deadline = Date().addingTimeInterval(25)
            }
            updateProgress()
            if ackedOffset >= totalBytes {
                beginVerify()
            } else {
                pump()
            }

        case "done":
            receivedDone = true
            if phase == .verifying || phase == .transferring {
                phase = .rebooting
                deadline = Date().addingTimeInterval(60)
            }

        case "err":
            let code = (json["m"] as? String) ?? ""
            fail(message(for: code), sendAbort: false)

        default:
            break
        }
    }

    /// Kaldes af BluetoothManager, når iOS igen kan modtage data uden svar.
    func transportReady() {
        pump()
    }

    /// Forbindelsen til pedalen blev afbrudt.
    func linkLost() {
        switch phase {
        case .preparing, .transferring:
            fail("Forbindelsen til pedalen blev afbrudt. Firmwaren er ikke ændret, og pedalen bruger stadig den gamle version.",
                 sendAbort: false)
        case .verifying:
            // Pedalen kan allerede være genstartet, før "done" nåede frem
            phase = .rebooting
            deadline = Date().addingTimeInterval(60)
        default:
            break
        }
    }

    // MARK: - Valg af fil

    func loadFile(_ url: URL) {
        guard !isBusy else { return }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let data = try Data(contentsOf: url)
            validate(data, name: url.lastPathComponent)
        } catch {
            image = nil
            fileName = url.lastPathComponent
            fileSize = 0
            fileError = "Kunne ikke læse filen."
        }
    }

    func clearFile() {
        guard !isBusy else { return }
        image = nil
        fileName = nil
        fileSize = 0
        fileError = nil
    }

    private func validate(_ data: Data, name: String) {
        image = nil
        fileName = name
        fileSize = data.count
        fileError = nil

        let lower = name.lowercased()

        if lower.hasSuffix(".ino") {
            fileError = "Det er kildekoden (.ino). Pedalen skal bruge den kompilerede fil. I Arduino IDE: Sketch → Export Compiled Binary."
            return
        }
        if lower.contains("merged") || lower.contains("bootloader") || lower.contains("partitions") {
            fileError = "Forkert fil. Brug filen, der ender på .ino.bin, ikke merged, bootloader eller partitions."
            return
        }
        guard data.count >= 100_000 else {
            fileError = "Filen er for lille til at være firmware."
            return
        }
        guard data[0] == 0xE9 else {
            fileError = "Filen ser ikke ud til at være en ESP32-firmware."
            return
        }
        // app-descriptor (magic 0xABCD5432) ligger på byte 32 i et almindeligt app-image
        guard data.count > 36, Array(data.subdata(in: 32..<36)) == [0x32, 0x54, 0xCD, 0xAB] else {
            fileError = "Filen er ikke et app-image. Brug filen, der ender på .ino.bin."
            return
        }
        if maxImageSize > 0, data.count > maxImageSize {
            fileError = "Firmwaren fylder \(format(data.count)), men pedalen har kun plads til \(format(maxImageSize))."
            return
        }
        image = data
    }

    // MARK: - Start / annullér

    func start() {
        guard !isBusy, let image, let transport else { return }

        if maxImageSize > 0, image.count > maxImageSize {
            fileError = "Firmwaren er større end pedalens OTA-plads (\(format(maxImageSize)))."
            return
        }
        guard otaPartitionAvailable else {
            fail(message(for: "nopart"), sendAbort: false)
            return
        }

        chunkSize = transport.otaChunkSize
        guard chunkSize >= 100 else {
            fail("Bluetooth-forbindelsen tillader kun små pakker (\(chunkSize) bytes). Forbind igen, og prøv på ny.",
                 sendAbort: false)
            return
        }

        sentOffset = 0
        ackedOffset = 0
        bytesAcked = 0
        progress = 0
        speedBytesPerSecond = 0
        etaSeconds = nil
        updatedVersion = nil
        receivedDone = false

        phase = .preparing
        deadline = Date().addingTimeInterval(45)     // sletning af flash kan tage op til ~15 sek.
        startTicker()
        transport.sendOtaCommand("ota:begin:\(image.count)")
    }

    func cancel() {
        guard isBusy, phase != .rebooting else { return }
        transport?.sendOtaCommand("ota:abort")
        stopTicker()
        phase = .failed("Opdateringen blev annulleret. Pedalen bruger stadig den gamle firmware.")
    }

    /// Tilbage til udgangsskærmen efter succes eller fejl.
    func acknowledgeResult() {
        switch phase {
        case .success, .failed: phase = .idle
        default: break
        }
    }

    // MARK: - Overførsel

    private func pump() {
        guard phase == .transferring, let transport, let image else { return }
        while sentOffset < image.count,
              sentOffset - ackedOffset < window,
              transport.canSendOtaData {
            let end = min(sentOffset + chunkSize, image.count)
            transport.sendOtaData(image.subdata(in: sentOffset..<end))
            sentOffset = end
        }
    }

    private func beginVerify() {
        guard phase == .transferring else { return }
        phase = .verifying
        deadline = Date().addingTimeInterval(30)
        transport?.sendOtaCommand("ota:end")
    }

    private func updateProgress() {
        bytesAcked = ackedOffset
        progress = totalBytes > 0 ? min(1, Double(ackedOffset) / Double(totalBytes)) : 0
    }

    private func finishSuccess(version: String) {
        stopTicker()
        progress = 1
        bytesAcked = totalBytes
        updatedVersion = version
        phase = .success
    }

    private func fail(_ message: String, sendAbort: Bool) {
        stopTicker()
        if sendAbort { transport?.sendOtaCommand("ota:abort") }
        phase = .failed(message)
    }

    // MARK: - Ur (hastighed, tid tilbage og timeouts)

    private func startTicker() {
        stopTicker()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
        deadline = nil
    }

    private func tick() {
        if phase == .transferring {
            let elapsed = Date().timeIntervalSince(startedAt)
            if elapsed > 1, ackedOffset > 0 {
                let speed = Double(ackedOffset) / elapsed
                speedBytesPerSecond = speed
                etaSeconds = speed > 0 ? Int((Double(totalBytes - ackedOffset) / speed).rounded(.up)) : nil
            }
        }

        if let deadline, Date() > deadline, isBusy {
            switch phase {
            case .rebooting:
                fail("Opdateringen blev sendt, men pedalen meldte sig ikke tilbage. Tjek, at den er tændt, og at appen er forbundet.",
                     sendAbort: false)
            default:
                fail("Pedalen svarer ikke. Gå tættere på, og prøv igen.", sendAbort: true)
            }
        }
    }

    // MARK: - Tekster

    private func message(for code: String) -> String {
        switch code {
        case "running":    return "Timeren kører. Stop den, og prøv igen."
        case "nopart":     return "Pedalen har ikke plads til OTA-opdatering. Den skal flashes én gang via USB med en partitionstabel, der har OTA."
        case "size":       return "Filens størrelse passer ikke til pedalens hukommelse."
        case "begin":      return "Pedalen kunne ikke gøre klar til opdatering."
        case "magic":      return "Filen er ikke gyldig firmware til denne pedal."
        case "write":      return "Pedalen kunne ikke skrive til hukommelsen."
        case "end":        return "Verificeringen fejlede. Firmwaren blev ikke installeret, og pedalen bruger stadig den gamle."
        case "overflow":   return "Pedalen kunne ikke følge med. Gå tættere på, og prøv igen."
        case "timeout":    return "Pedalen modtog ikke data i tide."
        case "disconnect": return "Forbindelsen blev afbrudt."
        case "busy":       return "Der er allerede en opdatering i gang."
        default:           return "Ukendt fejl (\(code))."
        }
    }

    private func format(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
