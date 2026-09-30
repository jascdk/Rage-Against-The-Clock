//
//  DiagnosticsView.swift
//  Rage Against The Time
//
//  Kort datasiden: forbindelse, signalstyrke, pedalens temperatur, MAC, hukommelse m.m.
//

import SwiftUI

struct DiagnosticsView: View {
    @ObservedObject var model: DiagnosticsModel
    @EnvironmentObject var bluetooth: BluetoothManager
    @Environment(\.dismiss) private var dismiss

    @State private var copied = false

    private let dash = "–"

    var body: some View {
        NavigationStack {
            List {
                if bluetooth.isConnected && !model.isSupported {
                    Section {
                        Label {
                            Text("Pedalens firmware har ikke diagnostik endnu. Opdatér til version 2.7.0 under Firmware. Har du lige opdateret, så slå Bluetooth fra og til på telefonen, fordi iOS husker den gamle tjenesteliste.")
                                .font(.footnote)
                        } icon: {
                            Image(systemName: "info.circle.fill").foregroundStyle(.orange)
                        }
                    }
                }

                connectionSection
                pedalSection
                commandsSection

                Section {
                    Button {
                        UIPasteboard.general.string = model.report(connected: bluetooth.isConnected)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                    } label: {
                        Label(copied ? "Kopieret" : "Kopiér rapport", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                } footer: {
                    Text("Samler alle tal i en tekst, du kan sende, hvis noget driller.")
                }
            }
            .navigationTitle("Diagnostik")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Luk") { dismiss() }
                }
            }
            .onAppear { model.start() }
            .onDisappear { model.stop() }
        }
    }

    // MARK: - Forbindelse

    private var connectionSection: some View {
        Section("Forbindelse") {
            HStack {
                Text("Status")
                Spacer()
                Circle()
                    .fill(bluetooth.isConnected ? Color.green : Color.gray)
                    .frame(width: 9, height: 9)
                Text(statusText)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Signalstyrke")
                Spacer()
                if let rssi = model.rssi {
                    SignalBars(bars: DiagnosticsModel.signalBars(rssi))
                    Text("\(rssi) dBm · \(DiagnosticsModel.signalText(rssi))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Text(dash).foregroundStyle(.secondary)
                }
            }

            if model.rssiHistory.count > 1 {
                RSSIHistory(values: model.rssiHistory)
                    .frame(height: 30)
                    .accessibilityHidden(true)
            }

            row("Svartid", model.latencyMs.map { "\($0) ms" })

            HStack {
                Text("Forbundet i")
                Spacer()
                if let since = model.connectedSince {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(DiagnosticsModel.uptimeText(max(0, Int(context.date.timeIntervalSince(since)))))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                } else {
                    Text(dash).foregroundStyle(.secondary)
                }
            }

            row("Genforbindelser", "\(model.reconnects)")
            row("Statusopdateringer", String(format: "%.1f pr. sekund", model.statusPerSecond))
            row("Største skrivepakke", model.maxWriteLength > 0 ? "\(model.maxWriteLength) byte" : nil)
            row("Telefonens ID for pedalen", model.peripheralShortID)
        }
    }

    private var statusText: String {
        switch bluetooth.connectionState {
        case .connected:     return "Forbundet"
        case .connecting:    return "Forbinder"
        case .searching:     return "Søger"
        case .bluetoothOff:  return "Bluetooth slået fra"
        case .unauthorized:  return "Ikke tilladt"
        case .unsupported:   return "Ikke understøttet"
        case .notStarted:    return "Ikke startet"
        }
    }

    // MARK: - Pedal

    private var pedalSection: some View {
        Section {
            HStack {
                Text("MAC-adresse")
                Spacer()
                Text(model.info?.mac ?? dash)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .contextMenu {
                        if let mac = model.info?.mac {
                            Button("Kopiér") { UIPasteboard.general.string = mac }
                        }
                    }
            }

            row("Firmware", model.info.map { "v\($0.firmware)" })
            row("Bygget", model.info?.buildDate)
            row("Chip", model.info.map { "\($0.chip) \(DiagnosticsModel.revisionText($0.revision)) · \($0.cpuMHz) MHz" })

            HStack {
                Text("Temperatur")
                Spacer()
                if let t = model.live?.tempC {
                    Image(systemName: "thermometer.medium")
                        .foregroundStyle(temperatureColor(t))
                    Text("\(t.formatted(.number.precision(.fractionLength(1)))) °C")
                        .foregroundStyle(temperatureColor(t))
                        .monospacedDigit()
                } else {
                    Text(dash).foregroundStyle(.secondary)
                }
            }

            row("Oppetid", model.live.map { DiagnosticsModel.uptimeText($0.uptimeSeconds) })
            row("Sidste nulstilling", model.live.map { DiagnosticsModel.resetText($0.resetReason) })
            row("Frit heap", model.live.map { "\($0.freeHeap / 1024) KB (laveste \($0.minHeap / 1024) KB)" })
            row("Flash", model.info.map { "\($0.flashBytes / 1_048_576) MB · firmware \($0.sketchBytes / 1024) KB" })
            row("Partition", model.info?.partition)
        } header: {
            Text("Pedal")
        } footer: {
            Text("Temperaturen er chippens egen kernetemperatur. Den er højere end rummets, fordi chippen selv varmer op. Brug den til at se tendenser og overophedning, ikke som rumtemperatur.")
        }
    }

    // MARK: - Kommandoer

    private var commandsSection: some View {
        Section {
            row("Modtaget", model.live.map { "\($0.commandsReceived)" })
            row("Tabt (kø fuld)", model.live.map { "\($0.commandsDropped)" })
            row("Afvist", model.live.map { "\($0.commandsRejected)" })
        } header: {
            Text("Kommandoer til pedalen")
        } footer: {
            Text("Tabte kommandoer betyder, at pedalen ikke nåede at behandle dem. Afviste er ugyldige eller kom på et forkert tidspunkt, fx skift af tilstand, mens timeren kører.")
        }
    }

    // MARK: - Hjælpere

    private func row(_ title: String, _ value: String?) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value ?? dash)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
        }
    }

    /// Vejledende grænser for chippens kernetemperatur
    private func temperatureColor(_ t: Double) -> Color {
        if t >= 80 { return .red }
        if t >= 60 { return .orange }
        return .green
    }
}

// MARK: - Signalstreger

private struct SignalBars: View {
    let bars: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(i <= bars ? Color.green : Color.secondary.opacity(0.3))
                    .frame(width: 4, height: CGFloat(4 + i * 3))
            }
        }
        .frame(height: 16)
        .accessibilityLabel("\(bars) af 4 signalstreger")
    }
}

// MARK: - Signalhistorik (de seneste målinger)

private struct RSSIHistory: View {
    let values: [Int]

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                let level = min(1, max(0, Double(v + 100) / 60))    // -100 dBm = 0, -40 dBm = 1
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(level > 0.55 ? Color.green : (level > 0.3 ? Color.orange : Color.red))
                    .frame(height: CGFloat(4 + level * 24))
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
