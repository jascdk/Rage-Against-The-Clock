//
//  ProfilesView.swift
//  Rage Against The Time
//
//  Profil-chip på hovedskærmen (menu med ét-tryks skift), liste til at administrere profiler og en editor.
//

import SwiftUI

// MARK: - Chip på hovedskærmen

struct ProfileChip: View {
    @EnvironmentObject var bluetooth: BluetoothManager
    @EnvironmentObject var store: ProfileStore

    @State private var showManage = false
    @State private var notice: String?

    private var activeProfile: GigProfile? {
        store.profiles.first { $0.matches(bluetooth) }
    }

    private var canApply: Bool {
        bluetooth.isConnected && !bluetooth.isTimerRunning
    }

    var body: some View {
        Menu {
            ForEach(store.profiles) { profile in
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    let warnings = store.apply(profile, to: bluetooth)
                    if !warnings.isEmpty { notice = warnings.joined(separator: "\n\n") }
                } label: {
                    if profile.matches(bluetooth) {
                        Label(profile.name, systemImage: "checkmark")
                    } else {
                        Text(profile.name)
                    }
                }
                .disabled(!canApply)
            }

            Divider()

            Button {
                showManage = true
            } label: {
                Label("Rediger profiler…", systemImage: "slider.horizontal.3")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "music.note.list")
                Text(activeProfile?.name.uppercased() ?? "PROFILER")
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.vertical, 7)
            .padding(.horizontal, 12)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .sheet(isPresented: $showManage) {
            ProfilesView()
                .environmentObject(bluetooth)
                .environmentObject(store)
        }
        .alert("Bemærk", isPresented: Binding(
            get: { notice != nil },
            set: { if !$0 { notice = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notice ?? "")
        }
    }
}

// MARK: - Liste

struct ProfilesView: View {
    @EnvironmentObject var bluetooth: BluetoothManager
    @EnvironmentObject var store: ProfileStore
    @Environment(\.dismiss) private var dismiss

    private struct AlertInfo {
        var title: String
        var message: String
        var dismissAfter: Bool
    }

    @State private var editing: GigProfile?
    @State private var alertInfo: AlertInfo?

    var body: some View {
        NavigationStack {
            List {
                if store.profiles.isEmpty {
                    Text("Ingen profiler endnu. Tryk + for at oprette en ud fra pedalens nuværende indstillinger.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                ForEach(store.profiles) { profile in
                    Button {
                        use(profile)
                    } label: {
                        row(profile)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .leading) {
                        Button("Rediger") { editing = profile }
                            .tint(.blue)
                    }
                    .contextMenu {
                        Button {
                            editing = profile
                        } label: {
                            Label("Rediger", systemImage: "pencil")
                        }
                    }
                }
                .onDelete(perform: store.delete)
                .onMove(perform: store.move)

                Section {
                    EmptyView()
                } footer: {
                    Text("Tryk for at bruge en profil. Stryg mod højre for at redigere, mod venstre for at slette. Profilen kan kun bruges, når pedalen er forbundet og standset, og den nulstiller timeren.")
                }
            }
            .navigationTitle("Gig-profiler")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        // Ny profil forudfyldt med pedalens nuværende indstillinger
                        editing = GigProfile.current(from: bluetooth)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Ny profil")
                }
            }
            .sheet(item: $editing) { profile in
                ProfileEditor(profile: profile) { saved in
                    store.upsert(saved)
                }
            }
            .alert(
                alertInfo?.title ?? "",
                isPresented: Binding(
                    get: { alertInfo != nil },
                    set: { if !$0 { alertInfo = nil } }
                ),
                presenting: alertInfo
            ) { info in
                Button("OK", role: .cancel) {
                    if info.dismissAfter { dismiss() }
                }
            } message: { info in
                Text(info.message)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ profile: GigProfile) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(profile.name)
                    .font(.headline)
                Text(profile.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if profile.matches(bluetooth) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .contentShape(Rectangle())
    }

    private func use(_ profile: GigProfile) {
        if !bluetooth.isConnected {
            alertInfo = AlertInfo(title: "Kan ikke bruge profilen",
                                  message: "Pedalen er ikke forbundet.",
                                  dismissAfter: false)
        } else if bluetooth.isTimerRunning {
            alertInfo = AlertInfo(title: "Kan ikke bruge profilen",
                                  message: "Timeren kører. Sæt den på pause, eller nulstil den, før du skifter profil.",
                                  dismissAfter: false)
        } else {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            let warnings = store.apply(profile, to: bluetooth)
            if warnings.isEmpty {
                dismiss()
            } else {
                alertInfo = AlertInfo(title: "Bemærk",
                                      message: warnings.joined(separator: "\n\n"),
                                      dismissAfter: true)
            }
        }
    }
}

// MARK: - Editor

struct ProfileEditor: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draft: GigProfile
    @State private var minutes: Int
    @State private var endEnabled: Bool
    @State private var startEnabled: Bool
    @State private var endDate: Date
    @State private var startDate: Date

    let onSave: (GigProfile) -> Void

    private let maxMinutes = 599   // pedalen kan vise op til 9t 59m

    init(profile: GigProfile, onSave: @escaping (GigProfile) -> Void) {
        _draft = State(initialValue: profile)
        _minutes = State(initialValue: max(1, profile.durationSeconds / 60))
        _endEnabled = State(initialValue: profile.endMinutes != nil)
        _startEnabled = State(initialValue: profile.endMinutes != nil && profile.startMinutes != nil)
        _endDate = State(initialValue: Self.date(minutes: profile.endMinutes ?? (21 * 60 + 45)))
        _startDate = State(initialValue: Self.date(minutes: profile.startMinutes ?? (21 * 60)))
        self.onSave = onSave
    }

    private static func date(minutes: Int) -> Date {
        Calendar.current.date(bySettingHour: (minutes / 60) % 24, minute: minutes % 60, second: 0, of: Date()) ?? Date()
    }

    // MARK: Afledte værdier

    private var isCountdown: Bool { draft.mode == "countdown" }

    /// Med både start og slut er varigheden givet af tidsplanen
    private var scheduleDerivesDuration: Bool { isCountdown && endEnabled && startEnabled }

    private var slotMinutes: Int {
        let s = GigProfile.minutesOfDay(startDate)
        let e = GigProfile.minutesOfDay(endDate)
        return (e - s + 1440) % 1440
    }

    private var durationValid: Bool {
        if draft.mode == "stopwatch" { return true }
        if scheduleDerivesDuration { return (1...maxMinutes).contains(slotMinutes) }
        return (1...maxMinutes).contains(minutes)
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty && durationValid
    }

    // MARK: Visning

    var body: some View {
        NavigationStack {
            Form {
                Section("Navn") {
                    TextField("Fx Klub 45 min", text: $draft.name)
                }

                Section("Timer") {
                    Picker("Tilstand", selection: $draft.mode) {
                        Text("Nedtælling").tag("countdown")
                        Text("Optælling").tag("countup")
                        Text("Stopur").tag("stopwatch")
                    }

                    if draft.mode != "stopwatch" {
                        if scheduleDerivesDuration {
                            HStack {
                                Text("Varighed")
                                Spacer()
                                Text(durationValid ? "\(slotMinutes) min (fra tidsplan)" : "Ugyldig tidsplan")
                                    .foregroundStyle(durationValid ? Color.secondary : Color.red)
                            }
                        } else {
                            HStack {
                                Text("Varighed")
                                Spacer()
                                TextField("Min", value: $minutes, format: .number)
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 70)
                                Text("min")
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Picker("Advarsel", selection: $draft.warningMinutes) {
                            Text("Fra").tag(0)
                            Text("1 min").tag(1)
                            Text("2 min").tag(2)
                            Text("3 min").tag(3)
                            Text("5 min").tag(5)
                        }
                    }

                    if isCountdown {
                        Toggle("Tillad under-run", isOn: $draft.underRun)
                        if draft.underRun {
                            Picker("Max under-run", selection: $draft.maxUnderRunMinutes) {
                                Text("5 min").tag(5)
                                Text("10 min").tag(10)
                                Text("15 min").tag(15)
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                }

                if isCountdown {
                    Section {
                        Toggle("Sluttidspunkt", isOn: $endEnabled.animation())
                        if endEnabled {
                            DatePicker("Slut kl.", selection: $endDate, displayedComponents: .hourAndMinute)
                            Toggle("Start automatisk", isOn: $startEnabled.animation())
                            if startEnabled {
                                DatePicker("Start kl.", selection: $startDate, displayedComponents: .hourAndMinute)
                            }
                        }
                    } header: {
                        Text("Tidsplan")
                    } footer: {
                        Text("Med sluttidspunkt tæller pedalen ned til klokkeslættet i stedet for en fast varighed. Kommer I sent i gang, mister I tiden automatisk. Med automatisk start sætter pedalen selv timeren i gang ved starttidspunktet, eller med det samme, hvis slottet allerede er begyndt. Varigheden ovenfor bruges kun, hvis pedalen nulstilles.")
                    }
                }

                Section("Lys og display") {
                    Toggle("Farveskift på LED", isOn: $draft.ledEscalation)
                    Toggle("Ur altid tændt", isOn: $draft.clockAlwaysOn)
                    sliderRow("Display 1 (ur)", value: $draft.brightness1, range: 0...7, step: 1, suffix: "/7")
                    sliderRow("Display 2 (timer)", value: $draft.brightness2, range: 0...7, step: 1, suffix: "/7")
                    sliderRow("Status LED", value: $draft.ledBrightness, range: 0...100, step: 5, suffix: "%")
                }
            }
            .navigationTitle(draft.name.isEmpty ? "Ny profil" : "Rediger profil")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuller") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Gem") { save() }
                        .disabled(!canSave)
                }
            }
        }
    }

    private func save() {
        var result = draft
        result.name = draft.name.trimmingCharacters(in: .whitespaces)

        if isCountdown && endEnabled {
            result.endMinutes = GigProfile.minutesOfDay(endDate)
            result.startMinutes = startEnabled ? GigProfile.minutesOfDay(startDate) : nil
        } else {
            result.endMinutes = nil
            result.startMinutes = nil
        }

        if result.mode != "stopwatch" {
            let mins = scheduleDerivesDuration ? slotMinutes : minutes
            result.durationSeconds = min(maxMinutes, max(1, mins)) * 60
        }

        onSave(result)
        dismiss()
    }

    private func sliderRow(_ title: String,
                           value: Binding<Int>,
                           range: ClosedRange<Double>,
                           step: Double,
                           suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value.wrappedValue)\(suffix)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { Double(value.wrappedValue) },
                    set: { value.wrappedValue = Int($0) }
                ),
                in: range,
                step: step
            )
        }
    }
}
