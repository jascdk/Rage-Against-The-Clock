//
//  Appearance.swift
//  Rage Against The Time
//
//  Valg af udseende: følg systemet, altid lys eller altid mørk.
//

import SwiftUI

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light:  return "Lys"
        case .dark:   return "Mørk"
        }
    }

    /// nil = følg systemets indstilling
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}
