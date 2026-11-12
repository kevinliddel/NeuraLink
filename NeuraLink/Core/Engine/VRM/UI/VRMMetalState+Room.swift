//
//  VRMMetalState+Room.swift
//  NeuraLink
//
//  Scene side of "a room that remembers" (CompanionRoom): the keepsakes
//  and their surface go up with the character and follow the environment
//  (table, suitcases or chest) and the keepsakes switch.
//
//  Created by Dedicatus on 05/11/2026.
//

import Foundation
import MetalKit

extension VRMMetalState {

    /// Puts this character's keepsakes beside them (VRMSceneView, once
    /// the model is displayed). Harmless to call again.
    func attachRoom(for character: String) {
        guard let model = currentModel, let device = mtkView.device, !character.isEmpty else { return }
        CompanionRoom.shared.place(
            character: character, on: model, device: device, environment: CompanionRoom.environmentKey
        ) { [weak self] in
            self?.renderer?.invalidateRenderItems()
        }
    }

    /// A keepsake landed mid-session: its object appears.
    func refreshRoom() {
        attachRoom(for: aiState.selectedCharacterName)
    }

    /// Per frame: the surface follows the environment and the switch.
    func updateRoom() {
        guard let model = currentModel else { return }
        if CompanionRoom.shared.follow(
            environment: CompanionRoom.environmentKey, visible: UserSettings.shared.showKeepsakes, on: model) {
            renderer?.invalidateRenderItems()
        }
    }
}
