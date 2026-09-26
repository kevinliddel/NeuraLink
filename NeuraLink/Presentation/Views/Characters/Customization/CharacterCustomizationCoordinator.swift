//
//  CharacterCustomizationCoordinator.swift
//  NeuraLink
//
//  Presentation flag for the customization panel. ContentView owns the
//  overlay; the model picker's context menu and PersonaSettingsView (from
//  inside the settings sheet) both open it through here.
//

import Foundation
import Observation

@Observable
@MainActor
final class CharacterCustomizationCoordinator {
    static let shared = CharacterCustomizationCoordinator()

    var isPresented = false

    private init() {}

    /// Presents the panel for the character currently on screen. Deferred
    /// one run-loop turn so a dismissing sheet finishes first.
    func present() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            isPresented = true
        }
    }
}
