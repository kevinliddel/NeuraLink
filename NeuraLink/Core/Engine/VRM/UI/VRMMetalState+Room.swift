//
//  VRMMetalState+Room.swift
//  NeuraLink
//
//  Scene side of "a room that remembers" (CompanionRoom): the keepsake
//  table goes up with the character and follows the environment and the
//  keepsakes switch.
//
//  Created by Dedicatus on 05/11/2026.
//

import Foundation
import MetalKit

extension VRMMetalState {

    /// Puts this character's keepsakes on the table (VRMSceneView, once
    /// the model is displayed). Harmless to call again.
    func attachRoom(for character: String) {
        guard let model = currentModel, let device = mtkView.device, !character.isEmpty else { return }
        CompanionRoom.shared.place(
            character: character, on: model, device: device, environment: UserSettings.shared.selectedEnvironment
        ) { [weak self] in
            self?.renderer?.invalidateRenderItems()
        }
    }

    /// A keepsake landed mid-session: its object appears.
    func refreshRoom() {
        attachRoom(for: aiState.selectedCharacterName)
    }

    /// Per frame: the table follows the environment and the switch.
    func updateRoom() {
        guard let model = currentModel else { return }
        if CompanionRoom.shared.follow(
            environment: UserSettings.shared.selectedEnvironment, visible: UserSettings.shared.showKeepsakes, on: model) {
            renderer?.invalidateRenderItems()
        }
    }
}
