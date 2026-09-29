//
//  OnboardingView.swift
//  Rage Against The Time
//

import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var bluetooth: BluetoothManager
    @Binding var isPresented: Bool

    @State private var currentTab = 0
    @State private var notificationsRequested = false

    private let lastTab = 4

    private var bluetoothStatus: (text: String, color: Color) {
        switch bluetooth.connectionState {
        case .connected:               return ("Pedal fundet!", .green)
        case .notStarted:              return ("Bluetooth er endnu ikke aktiveret", .gray)
        case .searching, .connecting:  return ("Søger efter pedal...", .orange)
        case .bluetoothOff:            return ("Bluetooth er slået fra", .red)
        case .unauthorized:            return ("Adgang til Bluetooth mangler", .red)
        case .unsupported:             return ("Bluetooth understøttes ikke", .red)
        }
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                HStack {
                    Spacer()
                    Button("Spring over") { completeOnboarding() }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 4)
                }
                .padding(.horizontal)
                .padding(.top, 8)

                TabView(selection: $currentTab) {
                    // Trin 1: Bluetooth
                    vStackStep(
                        icon: "antenna.radiowaves.left.and.right",
                        color: .blue,
                        title: "Rage Against The Time",
                        description: "Tænd for pedalen. Appen finder og forbinder automatisk via Bluetooth."
                    ) {
                        VStack(spacing: 14) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(bluetoothStatus.color)
                                    .frame(width: 10, height: 10)
                                Text(bluetoothStatus.text)
                                    .font(.caption)
                                    .fontWeight(.bold)
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 16)
                            .background(Color(uiColor: .secondarySystemBackground))
                            .clipShape(Capsule())
                            .accessibilityElement(children: .combine)

                            bluetoothActionButton
                        }
                    }
                    .tag(0)

                    // Trin 2: Modes
                    vStackStep(
                        icon: "timer",
                        color: .cyan,
                        title: "Tre tilstande",
                        description: "Nedtælling til dit sæt, optælling til øvning og stopur til alt andet. Få en advarsel, før tiden løber ud, og tillad evt. under-run."
                    )
                    .tag(1)

                    // Trin 3: Fodpedal
                    vStackStep(
                        icon: "shoeprints.fill",
                        color: .green,
                        title: "Styr med foden",
                        description: "Ét tryk starter eller pauser. To hurtige tryk nulstiller. Du behøver ikke røre telefonen under sættet."
                    )
                    .tag(2)

                    // Trin 4: Kontrol
                    vStackStep(
                        icon: "sun.max.fill",
                        color: .orange,
                        title: "Fuld kontrol",
                        description: "Juster displayets lysstyrke fra telefonen, og gem dine egne favorit-tider. Hold en tid nede for at ændre den."
                    )
                    .tag(3)

                    // Trin 5: Notifikationer
                    vStackStep(
                        icon: "bell.badge.fill",
                        color: .red,
                        title: "Notifikationer",
                        description: "Få besked på telefonen, når tiden er gået, også hvis skærmen er låst."
                    ) {
                        Button(notificationsRequested ? "Spurgt ✓" : "Tillad notifikationer") {
                            NotificationManager.shared.requestAuthorization()
                            notificationsRequested = true
                        }
                        .buttonStyle(.bordered)
                        .disabled(notificationsRequested)
                    }
                    .tag(4)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))

                Button(action: {
                    if currentTab < lastTab {
                        withAnimation { currentTab += 1 }
                    } else {
                        completeOnboarding()
                    }
                }) {
                    Text(currentTab == lastTab ? "Kom i gang" : "Næste")
                        .font(.headline)
                        .fontWeight(.bold)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(Color.blue)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
            }
        }
    }

    @ViewBuilder
    private var bluetoothActionButton: some View {
        switch bluetooth.connectionState {
        case .notStarted:
            Button("Tillad Bluetooth") { bluetooth.start() }
                .buttonStyle(.borderedProminent)
        case .unauthorized:
            Button("Åbn Indstillinger") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.bordered)
        default:
            EmptyView()
        }
    }

    private func completeOnboarding() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        bluetooth.start()                                   // ingen effekt, hvis den allerede kører
        NotificationManager.shared.requestAuthorization()   // ingen effekt, hvis svaret allerede er givet
        isPresented = false
    }

    @ViewBuilder
    private func vStackStep<Content: View>(
        icon: String,
        color: Color,
        title: String,
        description: String,
        @ViewBuilder extraContent: () -> Content = { EmptyView() }
    ) -> some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: icon)
                .font(.system(size: 70))
                .foregroundStyle(color)
                .padding(30)
                .background(color.opacity(0.12))
                .clipShape(Circle())

            Text(title)
                .font(.title)
                .fontWeight(.bold)

            Text(description)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)

            extraContent()

            Spacer()
        }
        .padding(.bottom, 30)   // luft til sideindikatorerne
    }
}
