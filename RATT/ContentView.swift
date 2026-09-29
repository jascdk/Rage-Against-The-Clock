//
//  ContentView.swift
//  Rage Against The Time
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var bluetooth: BluetoothManager

    @AppStorage("preset1") private var preset1: Int = 15
    @AppStorage("preset2") private var preset2: Int = 30
    @AppStorage("preset3") private var preset3: Int = 45
    @AppStorage("preset4") private var preset4: Int = 60
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false

    @State private var isPulsing = false
    @State private var showSideMenu = false
    @State private var showTimeSetup = false
    @State private var showFirmware = false

    @State private var editingPresetNumber: Int? = nil
    @State private var editPresetText = ""
    @State private var showEditPresetAlert = false

    @GestureState private var dragOffset: CGFloat = 0

    private let maxMinutes = 599   // pedalen kan vise op til 9t 59m

    // MARK: - Afledte værdier

    private var statusColor: Color {
        if !bluetooth.isConnected { return .gray }
        if bluetooth.isTimerDone { return .red }
        if bluetooth.isTimerRunning { return .cyan }
        return .green
    }

    private var progress: Double {
        let current = Double(bluetooth.remainingSeconds)
        if bluetooth.timerMode == "stopwatch" {
            return current >= 0 ? current.truncatingRemainder(dividingBy: 3600) / 3600 : 0
        }
        let total = Double(bluetooth.durationSeconds)
        guard total > 0 else { return 0 }
        return min(1, max(0, current / total))
    }

    private var connectionLabel: String {
        switch bluetooth.connectionState {
        case .connected:     return "PEDAL ONLINE"
        case .connecting:    return "FORBINDER..."
        case .searching:     return "SØGER PEDAL..."
        case .bluetoothOff:  return "BLUETOOTH ER SLÅET FRA"
        case .unauthorized:  return "BLUETOOTH IKKE TILLADT"
        case .unsupported:   return "BLUETOOTH IKKE TILGÆNGELIGT"
        case .notStarted:    return "BLUETOOTH IKKE STARTET"
        }
    }

    /// Klokkeslættet timeren slutter, regnet ud fra resttiden
    private var endClockText: String {
        Date().addingTimeInterval(TimeInterval(bluetooth.remainingSeconds))
            .formatted(date: .omitted, time: .shortened)
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geometry in
            let menuWidth = min(geometry.size.width * 0.85, 350)
            let menuOffset: CGFloat = showSideMenu
                ? min(menuWidth, max(0, dragOffset))
                : min(menuWidth, max(0, menuWidth + dragOffset))
            let openProgress = 1.0 - (menuOffset / menuWidth)

            ZStack(alignment: .trailing) {
                mainContent
                    .disabled(showSideMenu)
                    .blur(radius: openProgress * 3)

                if openProgress > 0.001 {
                    Color.black.opacity(0.3 * openProgress)
                        .ignoresSafeArea()
                        .onTapGesture { closeMenu() }
                        .gesture(closeDrag(menuWidth: menuWidth))
                }

                sideMenuView(menuWidth: menuWidth)
                    .offset(x: menuOffset)

                // Kant-zone til at swipe menuen ind fra højre
                if !showSideMenu {
                    Color.clear
                        .frame(width: 16)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .gesture(openDrag(menuWidth: menuWidth))
                }
            }
        }
        .sheet(isPresented: $showTimeSetup) {
            TimeSetupSheet(
                maxMinutes: maxMinutes,
                isRunning: bluetooth.isTimerRunning,
                onSetDuration: { mins in
                    bluetooth.sendCommand("duration:\(mins * 60)")
                },
                onSetEndTime: { hour, minute, startNow in
                    bluetooth.setEndTime(hour: hour, minute: minute, startNow: startNow)
                }
            )
        }
        .sheet(isPresented: $showFirmware) {
            FirmwareUpdateView(updater: bluetooth.firmware)
                .environmentObject(bluetooth)
        }
        .alert("Rediger præset (minutter)", isPresented: $showEditPresetAlert) {
            TextField("Minutter", text: $editPresetText)
                .keyboardType(.numberPad)
            Button("Gem") {
                if let mins = Int(editPresetText), (1...maxMinutes).contains(mins) {
                    switch editingPresetNumber {
                    case 1: preset1 = mins
                    case 2: preset2 = mins
                    case 3: preset3 = mins
                    case 4: preset4 = mins
                    default: break
                    }
                }
            }
            Button("Annuller", role: .cancel) {}
        } message: {
            Text("Hold en knap nede for at ændre tidsværdien (1–\(maxMinutes) min).")
        }
        .onAppear { isPulsing = bluetooth.isTimerRunning }
        .onChange(of: bluetooth.isTimerRunning) { _, newValue in isPulsing = newValue }
    }

    // MARK: - Hovedvisning

    private var mainContent: some View {
        ZStack {
            statusColor
                .opacity(isPulsing ? 0.25 : 0.08)
                .blur(radius: 60)
                .ignoresSafeArea()
                .animation(
                    bluetooth.isTimerRunning
                        ? Animation.easeInOut(duration: 1.5).repeatForever(autoreverses: true)
                        : .default,
                    value: isPulsing
                )

            VStack {
                headerView
                    .padding(.horizontal, 20)
                    .padding(.top, 10)

                ProfileChip()
                    .padding(.top, 8)

                bluetoothHelpView
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                Spacer()

                timerRingView

                Spacer()

                if bluetooth.timerMode != "stopwatch" {
                    mainScreenPresetsView
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                }

                controlButtonsSection
                    .padding(.horizontal, 20)
                    .padding(.bottom, 30)
            }
        }
    }

    private var headerView: some View {
        HStack {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: statusColor, radius: 4)

                Text(connectionLabel)
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            .background(.ultraThinMaterial, in: Capsule())

            Spacer()

            Button(action: { showSideMenu ? closeMenu() : openMenu() }) {
                Image(systemName: "line.3.horizontal.decrease.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.primary)
                    .padding(6)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Indstillinger")
        }
    }

    @ViewBuilder
    private var bluetoothHelpView: some View {
        switch bluetooth.connectionState {
        case .bluetoothOff:
            Text("Slå Bluetooth til i Kontrolcenter for at forbinde til pedalen.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        case .unauthorized:
            VStack(spacing: 8) {
                Text("Appen har ikke adgang til Bluetooth.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Åbn Indstillinger") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
            }
        default:
            EmptyView()
        }
    }

    // MARK: - Ring

    private var timeText: String {
        if !bluetooth.isConnected && !bluetooth.hasReceivedStatus { return "--:--" }
        return formattedTime(bluetooth.remainingSeconds)
    }

    private var timeColor: Color {
        if !bluetooth.isConnected { return .secondary }
        if bluetooth.isTimerDone { return .red }
        return .primary
    }

    private var timerRingView: some View {
        ZStack {
            Circle()
                .stroke(statusColor.opacity(0.1), lineWidth: 26)

            Circle()
                .trim(from: 0, to: CGFloat(progress))
                .stroke(
                    AngularGradient(colors: [statusColor, .blue, statusColor], center: .center),
                    style: StrokeStyle(lineWidth: 20, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.spring(response: 0.6, dampingFraction: 0.8), value: progress)
                .shadow(color: statusColor.opacity(0.5), radius: 12, x: 0, y: 0)

            VStack(spacing: 6) {
                Text(bluetooth.timerMode.uppercased())
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .tracking(4)

                Text(timeText)
                    .font(.system(size: 50, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .foregroundStyle(timeColor)

                if bluetooth.endAtActive && bluetooth.timerMode == "countdown" && bluetooth.isConnected {
                    Label("SLUT KL. \(endClockText)", systemImage: "clock.badge.checkmark")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                if bluetooth.startAtActive && bluetooth.isConnected {
                    Label("STARTER AUTOMATISK", systemImage: "play.circle")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                if !bluetooth.isConnected && bluetooth.hasReceivedStatus {
                    badge("FORBINDELSE TABT", color: .orange)
                } else if bluetooth.isTimerDone {
                    badge("🎉 TIDEN ER GÅET 🎉", color: .red)
                }
            }
            .padding(.horizontal, 15)
        }
        .frame(width: 290, height: 290)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .heavy))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color)
            .foregroundStyle(.white)
            .clipShape(Capsule())
            .transition(.scale)
    }

    // MARK: - Presets

    private var mainScreenPresetsView: some View {
        HStack(spacing: 10) {
            Group {
                mainPresetButton(minutes: preset1, number: 1)
                mainPresetButton(minutes: preset2, number: 2)
                mainPresetButton(minutes: preset3, number: 3)
                mainPresetButton(minutes: preset4, number: 4)
            }
            .disabled(!bluetooth.isConnected || bluetooth.isTimerRunning)
            .opacity((!bluetooth.isConnected || bluetooth.isTimerRunning) ? 0.4 : 1.0)

            // Tidsindstilling er tilgængelig under kørsel, så sluttidspunktet kan justeres midt i et sæt
            customPresetButton
                .disabled(!bluetooth.isConnected)
                .opacity(bluetooth.isConnected ? 1.0 : 0.4)
        }
    }

    private func presetLabel(_ minutes: Int) -> String {
        (minutes >= 60 && minutes % 60 == 0) ? "\(minutes / 60)t" : "\(minutes)m"
    }

    private func mainPresetButton(minutes: Int, number: Int) -> some View {
        let isSelected = !bluetooth.endAtActive && bluetooth.durationSeconds == minutes * 60
        // Almindelig view med tap + long press, så et langt tryk ikke også udløser tap
        return Text(presetLabel(minutes))
            .font(.system(size: 14, weight: .bold, design: .rounded))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(isSelected ? statusColor : Color(uiColor: .tertiarySystemFill))
            .foregroundStyle(isSelected ? Color.black : Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .onTapGesture {
                triggerHaptic(.medium)
                bluetooth.sendCommand("duration:\(minutes * 60)")
            }
            .onLongPressGesture(minimumDuration: 0.6) {
                triggerHaptic(.heavy)
                editingPresetNumber = number
                editPresetText = "\(minutes)"
                showEditPresetAlert = true
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Hold nede for at ændre tiden")
    }

    private var customPresetButton: some View {
        Image(systemName: bluetooth.endAtActive ? "clock.badge.checkmark" : "slider.horizontal.3")
            .font(.system(size: 14, weight: .bold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(bluetooth.endAtActive ? statusColor : Color(uiColor: .tertiarySystemFill))
            .foregroundStyle(bluetooth.endAtActive ? Color.black : Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .onTapGesture {
                triggerHaptic(.medium)
                showTimeSetup = true
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Egen tid eller sluttidspunkt")
    }

    // MARK: - Start / nulstil

    private var controlButtonsSection: some View {
        HStack(spacing: 14) {
            Button(action: {
                triggerHaptic(.heavy)
                bluetooth.sendCommand(bluetooth.isTimerRunning ? "stop" : "start")
            }) {
                HStack(spacing: 10) {
                    Image(systemName: bluetooth.isTimerRunning ? "pause.fill" : "play.fill")
                    Text(bluetooth.isTimerRunning ? "PAUSE" : "START")
                }
                .font(.system(size: 18, weight: .black, design: .rounded))
                .frame(maxWidth: .infinity)
                .frame(height: 64)
                .background(bluetooth.isTimerRunning ? Color.orange : Color.green)
                .foregroundStyle(.black)
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .shadow(color: (bluetooth.isTimerRunning ? Color.orange : Color.green).opacity(0.4), radius: 12, y: 6)
            }

            Button(action: {
                triggerHaptic(.rigid)
                bluetooth.sendCommand("reset")   // nulstiller også et slut-klokkeslot
            }) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.title2.bold())
                    .frame(width: 64, height: 64)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
                    .foregroundStyle(.primary)
            }
            .accessibilityLabel("Nulstil")
        }
        .disabled(!bluetooth.isConnected)
        .opacity(bluetooth.isConnected ? 1.0 : 0.4)
    }

    // MARK: - Sidemenu

    private func sideMenuView(menuWidth: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Indstillinger")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Spacer()
                    Button(action: { closeMenu() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Luk")
                }
                .padding(.top, 40)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {

                        VStack(alignment: .leading, spacing: 8) {
                            Text("TILSTAND")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(.secondary)
                            modeSelectorSection
                        }

                        warningSection

                        settingCard {
                            settingToggle("Ur altid tændt",
                                          "Viser uret på Display 1 selv ved inaktivitet",
                                          isOn: bluetooth.clockAlwaysOn,
                                          command: "clockalways")
                        }

                        underRunSection

                        screensaverSection

                        SliderCard(title: "Lysstyrke Display 1 (Ur)", icon: "clock.fill",
                                   value: bluetooth.brightness1, range: 0...7, step: 1, suffix: "/7",
                                   tint: statusColor) { v in
                            triggerHaptic(.light)
                            bluetooth.sendCommand("brightness1:\(v)")
                        }
                        .disabled(!bluetooth.isConnected)

                        SliderCard(title: "Lysstyrke Display 2 (Timer)", icon: "timer",
                                   value: bluetooth.brightness2, range: 0...7, step: 1, suffix: "/7",
                                   tint: statusColor) { v in
                            triggerHaptic(.light)
                            bluetooth.sendCommand("brightness2:\(v)")
                        }
                        .disabled(!bluetooth.isConnected)

                        ledSection

                        hardwareSection

                        firmwareSection

                        appSection
                    }
                    .padding(.vertical, 10)
                }

                Spacer()
            }
            .padding(.horizontal, 20)
        }
        .frame(width: menuWidth)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .shadow(color: Color.black.opacity(0.25), radius: 20, x: -10, y: 0)
    }

    private var modeSelectorSection: some View {
        Picker("Timer Tilstand", selection: Binding(
            get: { bluetooth.timerMode },
            set: { newMode in
                triggerHaptic(.medium)
                bluetooth.sendCommand("mode:\(newMode)")
            }
        )) {
            Text("Nedtælling").tag("countdown")
            Text("Optælling").tag("countup")
            Text("Stopur").tag("stopwatch")
        }
        .pickerStyle(.segmented)
        .disabled(!bluetooth.isConnected || bluetooth.isTimerRunning)
    }

    private var warningSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ADVARSEL NÅR DER ER TILBAGE")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)

            Picker("Advarsel", selection: Binding(
                get: { bluetooth.warningTime },
                set: { warn in
                    triggerHaptic(.light)
                    bluetooth.sendCommand("warning:\(warn)")
                }
            )) {
                Text("Fra").tag(0)
                Text("1 min").tag(1)
                Text("2 min").tag(2)
                Text("3 min").tag(3)
                Text("5 min").tag(5)
            }
            .pickerStyle(.segmented)
        }
        .disabled(!bluetooth.isConnected)
    }

    private var underRunSection: some View {
        settingCard {
            VStack(alignment: .leading, spacing: 12) {
                settingToggle("Tillad Under-run",
                              "Fortsæt optælling under 0:00",
                              isOn: bluetooth.underRunEnabled,
                              command: "underrun")

                if bluetooth.underRunEnabled {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("MAX UNDER-RUN TID")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)

                        Picker("Max Under-run", selection: Binding(
                            get: { bluetooth.maxUnderRunMinutes },
                            set: { mins in
                                triggerHaptic(.light)
                                bluetooth.sendCommand("maxunderrun:\(mins)")
                            }
                        )) {
                            Text("5 min").tag(5)
                            Text("10 min").tag(10)
                            Text("15 min").tag(15)
                        }
                        .pickerStyle(.segmented)
                    }
                }
            }
        }
    }

    private var screensaverSection: some View {
        settingCard {
            VStack(alignment: .leading, spacing: 12) {
                settingToggle("Pauseskærm",
                              "Slukker displays efter inaktivitet",
                              isOn: bluetooth.screensaverEnabled,
                              command: "screensaver")

                if bluetooth.screensaverEnabled {
                    Picker("Efter", selection: Binding(
                        get: { bluetooth.screensaverMinutes },
                        set: { mins in
                            triggerHaptic(.light)
                            bluetooth.sendCommand("screensavermin:\(mins)")
                        }
                    )) {
                        Text("1 min").tag(1)
                        Text("2 min").tag(2)
                        Text("5 min").tag(5)
                        Text("10 min").tag(10)
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
    }

    private var ledSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingCard {
                settingToggle("Farveskift på LED",
                              "Grøn → gul → orange → rød blink, jo tættere på slut",
                              isOn: bluetooth.ledEscalation,
                              command: "ledesc")
            }

            SliderCard(title: "Status LED Lysstyrke", icon: "lightbulb.fill",
                       value: bluetooth.ledBrightness, range: 0...100, step: 5, suffix: "%",
                       tint: statusColor) { v in
                triggerHaptic(.light)
                bluetooth.sendCommand("ledbrightness:\(v)")
            }
            .disabled(!bluetooth.isConnected)
        }
    }

    private var hardwareSection: some View {
        settingCard {
            VStack(alignment: .leading, spacing: 14) {
                settingToggle("Byt om på Displays",
                              "Skifter rækkefølge (viser 1 og 2 ved ændring)",
                              isOn: bluetooth.swapDisplays,
                              command: "swapdisplays")

                Divider()

                settingToggle("Vend Display (180°)",
                              "Roterer cifre og punktum helt om",
                              isOn: bluetooth.displayFlipped,
                              command: "flip")
            }
        }
    }

    private var firmwareSection: some View {
        Button {
            closeMenu()
            showFirmware = true
        } label: {
            HStack {
                Label("Firmware", systemImage: "cpu")
                    .font(.system(size: 14, weight: .bold))
                Spacer()
                Text(bluetooth.firmware.deviceVersion.map { "v\($0)" } ?? "–")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(Color(uiColor: .tertiarySystemFill))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .disabled(!bluetooth.isConnected)
    }

    private var appSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                triggerHaptic(.light)
                bluetooth.forgetDevice()
            } label: {
                Label("Søg efter anden pedal", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 14, weight: .semibold))
            }

            Button {
                closeMenu()
                hasCompletedOnboarding = false
            } label: {
                Label("Vis intro igen", systemImage: "questionmark.circle")
                    .font(.system(size: 14, weight: .semibold))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .tertiarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Genbrugelige dele

    private func settingCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .tertiarySystemFill))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .disabled(!bluetooth.isConnected)
    }

    private func settingToggle(_ title: String, _ subtitle: String, isOn: Bool, command: String) -> some View {
        Toggle(isOn: Binding(
            get: { isOn },
            set: { value in
                triggerHaptic(.light)
                bluetooth.sendCommand("\(command):\(value ? "on" : "off")")
            }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .tint(statusColor)
    }

    // MARK: - Menu-gestures

    private func openDrag(menuWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($dragOffset) { value, state, _ in
                state = min(0, value.translation.width)
            }
            .onEnded { value in
                if value.translation.width < -menuWidth * 0.3 || value.predictedEndTranslation.width < -150 {
                    openMenu()
                }
            }
    }

    private func closeDrag(menuWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($dragOffset) { value, state, _ in
                state = max(0, value.translation.width)
            }
            .onEnded { value in
                if value.translation.width > menuWidth * 0.3 || value.predictedEndTranslation.width > 150 {
                    closeMenu()
                }
            }
    }

    private func openMenu() {
        triggerHaptic(.light)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { showSideMenu = true }
    }

    private func closeMenu() {
        triggerHaptic(.light)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { showSideMenu = false }
    }

    private func triggerHaptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    private func formattedTime(_ totalSeconds: Int) -> String {
        let neg = totalSeconds < 0
        let absSec = abs(totalSeconds)
        let hours = absSec / 3600
        let minutes = (absSec % 3600) / 60
        let seconds = absSec % 60
        let prefix = neg ? "-" : ""
        if hours > 0 {
            return String(format: "%@%d:%02d:%02d", prefix, hours, minutes, seconds)
        }
        return String(format: "%@%02d:%02d", prefix, minutes, seconds)
    }
}

// MARK: - Tidsindstilling (varighed eller slut-klokkeslot)

private struct TimeSetupSheet: View {
    enum Kind: String, CaseIterable, Identifiable {
        case duration = "Varighed"
        case endTime = "Slut kl."
        var id: String { rawValue }
    }

    let maxMinutes: Int
    let isRunning: Bool
    let onSetDuration: (Int) -> Void
    let onSetEndTime: (Int, Int, Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var kind: Kind
    @State private var minutesText = ""
    @State private var endTime: Date = Date().addingTimeInterval(3600)
    @State private var startNow = true

    private let maxEndSeconds = 35_999   // 9t 59m 59s

    init(maxMinutes: Int,
         isRunning: Bool,
         onSetDuration: @escaping (Int) -> Void,
         onSetEndTime: @escaping (Int, Int, Bool) -> Void) {
        self.maxMinutes = maxMinutes
        self.isRunning = isRunning
        self.onSetDuration = onSetDuration
        self.onSetEndTime = onSetEndTime
        // Under kørsel kan varigheden ikke ændres, kun sluttidspunktet
        _kind = State(initialValue: isRunning ? .endTime : .duration)
    }

    // MARK: Beregninger

    private var durationValid: Bool {
        if let mins = Int(minutesText) { return (1...maxMinutes).contains(mins) }
        return false
    }

    private var endComponents: DateComponents {
        Calendar.current.dateComponents([.hour, .minute], from: endTime)
    }

    /// Sekunder til næste forekomst af det valgte klokkeslæt
    private var secondsUntilEnd: Int {
        let match = DateComponents(hour: endComponents.hour, minute: endComponents.minute, second: 0)
        guard let target = Calendar.current.nextDate(after: Date(), matching: match, matchingPolicy: .nextTime) else {
            return 0
        }
        return Int(target.timeIntervalSinceNow.rounded())
    }

    private var endTimeValid: Bool { (1...maxEndSeconds).contains(secondsUntilEnd) }

    private func humanDuration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) sek." }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        return h > 0 ? "\(h)t \(m)m" : "\(m) min"
    }

    // MARK: Visning

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if !isRunning {
                    Picker("Type", selection: $kind) {
                        ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                switch kind {
                case .duration: durationForm
                case .endTime:  endTimeForm
                }

                Spacer()
            }
            .padding()
            .navigationTitle(kind == .duration ? "Brugerdefineret tid" : "Sæt sluttidspunkt")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }

    private var durationForm: some View {
        VStack(spacing: 16) {
            Text("Indtast varighed i minutter (1–\(maxMinutes))")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField("F.eks. 25", text: $minutesText)
                .keyboardType(.numberPad)
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
                .padding()
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16))

            Button {
                if let mins = Int(minutesText), (1...maxMinutes).contains(mins) {
                    onSetDuration(mins)
                    dismiss()
                }
            } label: {
                primaryLabel("Sæt timer", enabled: durationValid)
            }
            .disabled(!durationValid)
        }
    }

    private var endTimeForm: some View {
        VStack(spacing: 12) {
            DatePicker("Slut kl.", selection: $endTime, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .labelsHidden()

            Text(endTimeValid
                 ? "Om \(humanDuration(secondsUntilEnd))"
                 : "Sluttidspunktet skal ligge inden for de næste 9t 59m")
                .font(.footnote)
                .foregroundStyle(endTimeValid ? Color.secondary : Color.red)

            Toggle("Start med det samme", isOn: $startNow)
                .disabled(isRunning)

            Button {
                if endTimeValid, let h = endComponents.hour, let m = endComponents.minute {
                    onSetEndTime(h, m, startNow && !isRunning)
                    dismiss()
                }
            } label: {
                primaryLabel("Sæt sluttidspunkt", enabled: endTimeValid)
            }
            .disabled(!endTimeValid)
        }
    }

    private func primaryLabel(_ text: String, enabled: Bool) -> some View {
        Text(text)
            .font(.headline)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(enabled ? Color.blue : Color.gray)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Slider-kort
// Holder sin egen værdi under drag, så indkommende status ikke flytter slideren under fingeren.

private struct SliderCard: View {
    let title: String
    let icon: String
    let value: Int
    let range: ClosedRange<Double>
    let step: Double
    let suffix: String
    let tint: Color
    let onCommit: (Int) -> Void

    @State private var draft: Double = 0
    @State private var isEditing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(draft))\(suffix)")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Slider(value: $draft, in: range, step: step) { editing in
                isEditing = editing
                if !editing { onCommit(Int(draft)) }
            }
            .tint(tint)
        }
        .padding(14)
        .background(Color(uiColor: .tertiarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onAppear { draft = Double(value) }
        .onChange(of: value) { _, newValue in
            if !isEditing { draft = Double(newValue) }
        }
    }
}
