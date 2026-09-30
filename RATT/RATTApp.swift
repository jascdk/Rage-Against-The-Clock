//
//  RATTApp.swift
//  Rage Against The Time
//

import SwiftUI
import UserNotifications

@main
struct RATTApp: App {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false
    @AppStorage("appearanceMode") private var appearanceRaw: String = AppearanceMode.system.rawValue

    // Den eneste BluetoothManager i appen. Alle views bruger @EnvironmentObject.
    @StateObject private var bluetooth = BluetoothManager()

    // Gemte gig-profiler
    @StateObject private var profileStore = ProfileStore()

    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    private var onboardingBinding: Binding<Bool> {
        Binding(
            get: { !hasCompletedOnboarding },
            set: { hasCompletedOnboarding = !$0 }
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bluetooth)
                .environmentObject(profileStore)
                .preferredColorScheme(AppearanceMode(rawValue: appearanceRaw)?.colorScheme)
                .sheet(isPresented: onboardingBinding) {
                    OnboardingView(isPresented: onboardingBinding)
                        .environmentObject(bluetooth)
                        .interactiveDismissDisabled()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        UIApplication.shared.isIdleTimerDisabled = bluetooth.isConnected
                        bluetooth.appDidBecomeActive()
                    }
                }
                .onChange(of: bluetooth.connectionState) { _, state in
                    // Skærmen skal ikke slukke, mens pedalen er forbundet
                    UIApplication.shared.isIdleTimerDisabled = (state == .connected)
                }
        }
    }
}

/// Viser banners, mens appen er åben i forgrunden.
class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
