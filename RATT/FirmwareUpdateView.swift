//
//  FirmwareUpdateView.swift
//  Rage Against The Time
//
//  Skærm til firmwareopdatering over Bluetooth.
//

import SwiftUI
import UniformTypeIdentifiers

struct FirmwareUpdateView: View {
    @ObservedObject var updater: FirmwareUpdater
    @EnvironmentObject var bluetooth: BluetoothManager
    @Environment(\.dismiss) private var dismiss

    @State private var showImporter = false
    @State private var showConfirm = false

    // MARK: - Afledte værdier

    private var canStart: Bool {
        updater.hasValidFile
            && bluetooth.isConnected
            && !bluetooth.isTimerRunning
            && updater.isSupported
            && updater.otaPartitionAvailable
            && !updater.isBusy
    }

    /// Forklarer, hvorfor knappen er slået fra
    private var blocker: String? {
        if !bluetooth.isConnected { return "Pedalen er ikke forbundet." }
        if !updater.isSupported { return "Pedalens nuværende firmware understøtter ikke opdatering via Bluetooth. Den skal flashes én gang via USB. Slå evt. Bluetooth fra og til på telefonen, hvis du lige har flashet." }
        if !updater.otaPartitionAvailable { return "Pedalen har ikke plads til OTA. Flash den én gang via USB med en partitionstabel, der har OTA." }
        if bluetooth.isTimerRunning { return "Timeren kører. Stop den, før du opdaterer." }
        if updater.fileName == nil { return "Vælg firmware-filen først." }
        return nil
    }

    private var sizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(updater.fileSize), countStyle: .file)
    }

    private func bytes(_ value: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }

    private var speedText: String {
        guard updater.speedBytesPerSecond > 0 else { return "Måler hastighed…" }
        return String(format: "%.1f KB/s", updater.speedBytesPerSecond / 1024)
    }

    private var etaText: String {
        guard let eta = updater.etaSeconds else { return "" }
        if eta < 60 { return "ca. \(eta) sek. tilbage" }
        return "ca. \(eta / 60) min \(eta % 60) sek. tilbage"
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    deviceCard
                    statusCard

                    if updater.isBusy {
                        warningCard
                    } else {
                        helpCard
                    }
                }
                .padding()
            }
            .navigationTitle("Firmware")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !updater.isBusy {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Luk") { dismiss() }
                    }
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [UTType(filenameExtension: "bin") ?? .data, .data]
            ) { result in
                if case .success(let url) = result {
                    updater.loadFile(url)
                }
            }
            .confirmationDialog("Opdatér pedalens firmware?",
                                isPresented: $showConfirm,
                                titleVisibility: .visible) {
                Button("Start opdatering") { updater.start() }
                Button("Annuller", role: .cancel) {}
            } message: {
                Text("Opdateringen tager cirka ét til to minutter, og pedalen genstarter til sidst. Hold appen åben, og sluk ikke pedalen.")
            }
        }
        .interactiveDismissDisabled(updater.isBusy)
    }

    // MARK: - Kort

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .padding(18)
            .frame(maxWidth: .infinity)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var deviceCard: some View {
        card {
            HStack(spacing: 14) {
                Image(systemName: "cpu")
                    .font(.system(size: 26))
                    .foregroundStyle(.blue)
                    .frame(width: 48, height: 48)
                    .background(Color.blue.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Rage Against The Time")
                        .font(.headline)
                    Text(updater.deviceVersion.map { "Firmware v\($0)" } ?? "Version ukendt")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Circle()
                    .fill(bluetooth.isConnected ? Color.green : Color.gray)
                    .frame(width: 10, height: 10)
                    .accessibilityLabel(bluetooth.isConnected ? "Forbundet" : "Ikke forbundet")
            }
        }
    }

    @ViewBuilder
    private var statusCard: some View {
        card {
            switch updater.phase {
            case .idle:
                idleContent
            case .preparing:
                busyContent(title: "Forbereder pedalen",
                            detail: "Hukommelsen gøres klar. Det tager op til 15 sekunder.",
                            showFullBar: false)
            case .transferring:
                transferContent
            case .verifying:
                busyContent(title: "Verificerer firmware",
                            detail: "Pedalen kontrollerer filen, før den tages i brug.",
                            showFullBar: true)
            case .rebooting:
                busyContent(title: "Genstarter pedalen",
                            detail: "Pedalen starter med den nye firmware og forbinder igen.",
                            showFullBar: true)
            case .success:
                successContent
            case .failed(let message):
                failedContent(message)
            }
        }
    }

    // MARK: - Indhold pr. tilstand

    private var idleContent: some View {
        VStack(spacing: 16) {
            if let name = updater.fileName {
                HStack(spacing: 12) {
                    Image(systemName: updater.fileError == nil ? "doc.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(updater.fileError == nil ? Color.blue : Color.red)
                        .font(.title2)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(sizeText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Skift") { showImporter = true }
                        .font(.subheadline.weight(.semibold))
                }

                if let error = updater.fileError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Button {
                    showImporter = true
                } label: {
                    VStack(spacing: 10) {
                        Image(systemName: "square.and.arrow.down.on.square")
                            .font(.system(size: 34))
                        Text("Vælg firmware-fil (.bin)")
                            .font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 26)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7]))
                            .foregroundStyle(.secondary)
                    )
                }
                .buttonStyle(.plain)
            }

            Button {
                showConfirm = true
            } label: {
                Text("Opdatér pedal")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(canStart ? Color.blue : Color.gray.opacity(0.35))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .disabled(!canStart)

            if let blocker, !canStart {
                Text(blocker)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var transferContent: some View {
        VStack(spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(Int(updater.progress * 100))%")
                    .font(.system(size: 48, weight: .black, design: .rounded))
                    .monospacedDigit()

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(speedText)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                    Text(etaText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            FirmwareProgressBar(value: updater.progress)

            HStack {
                Text("\(bytes(updater.bytesAcked)) af \(sizeText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
            }

            Button("Annuller", role: .destructive) {
                updater.cancel()
            }
            .font(.subheadline.weight(.semibold))
        }
    }

    private func busyContent(title: String, detail: String, showFullBar: Bool) -> some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)

            Text(title)
                .font(.headline)

            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if showFullBar {
                FirmwareProgressBar(value: 1)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var successContent: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 52))
                .foregroundStyle(.green)

            Text("Firmware opdateret")
                .font(.title3.weight(.bold))

            if let version = updater.updatedVersion {
                Text("Pedalen kører nu version \(version)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Button {
                updater.acknowledgeResult()
                dismiss()
            } label: {
                Text("Færdig")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color.green)
                    .foregroundStyle(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .padding(.top, 4)
        }
    }

    private func failedContent(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 46))
                .foregroundStyle(.orange)

            Text("Opdateringen mislykkedes")
                .font(.title3.weight(.bold))

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                updater.acknowledgeResult()
            } label: {
                Text("Tilbage")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color.blue)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Advarsel og hjælp

    private var warningCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Hold appen åben og telefonen tæt på pedalen. Sluk ikke pedalen, før opdateringen er færdig.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var helpCard: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                Text("1. Åbn sketchen i Arduino IDE, og vælg Sketch → Export Compiled Binary.")
                Text("2. Find filen, der ender på .ino.bin, i mappen \"build\" i sketch-mappen. Brug ikke _flashed, .merged.bin, .bootloader.bin eller .partitions.bin.")
                Text("3. Send filen til din iPhone (AirDrop eller iCloud Drive), og vælg den her.")
                Text("Første gang skal pedalen flashes via USB med en partitionstabel, der har OTA, fx \"Default 4MB with spiffs\". Herefter kan den opdateres trådløst.")
                    .foregroundStyle(.secondary)
            }
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
        } label: {
            Label("Sådan får du firmware-filen", systemImage: "questionmark.circle")
                .font(.subheadline.weight(.semibold))
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Fremdriftsbar

private struct FirmwareProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.10))

                Capsule()
                    .fill(LinearGradient(colors: [.blue, .cyan],
                                         startPoint: .leading,
                                         endPoint: .trailing))
                    .frame(width: max(12, geometry.size.width * CGFloat(min(1, max(0, value)))))
                    .animation(.easeOut(duration: 0.25), value: value)
            }
        }
        .frame(height: 12)
        .accessibilityElement()
        .accessibilityLabel("Fremdrift")
        .accessibilityValue("\(Int(value * 100)) procent")
    }
}
