//
//  RenderPrioritySystem.swift
//  NeuraLink
//
//  Created by Dedicatus on 16/04/2026.
//

import Foundation
import Metal
import simd

/// Multi-character priority system for hybrid rendering
/// Automatically determines which characters render as full 3D vs cached sprites
public class CharacterPrioritySystem {

    // MARK: - Character Role

    /// Character's role in the current scene
    public enum CharacterRole {
        case mainSpeaker  // Primary character speaking
        case listener  // Active listener (reacting)
        case background  // Background/inactive character
        case offscreen  // Not visible in current frame
    }

    // MARK: - Character State

    /// Information about a character in the scene
    public struct CharacterState {
        /// Unique identifier
        public let characterID: String

        /// Display name (for debugging)
        public let displayName: String

        /// Current role in scene
        public var role: CharacterRole

        /// World position
        public var position: SIMD3<Float>

        /// Distance from camera
        public var distanceFromCamera: Float

        /// Is character currently animated?
        public var isAnimating: Bool

        /// Time since last role change (for hysteresis)
        public var timeSinceRoleChange: TimeInterval

        /// Preferred rendering mode (can be overridden by budget)
        public var preferredMode: RenderingDecision

        public init(
            characterID: String,
            displayName: String,
            role: CharacterRole = .background,
            position: SIMD3<Float> = SIMD3<Float>(0, 0, 0),
            distanceFromCamera: Float = 0,
            isAnimating: Bool = false
        ) {
            self.characterID = characterID
            self.displayName = displayName
            self.role = role
            self.position = position
            self.distanceFromCamera = distanceFromCamera
            self.isAnimating = isAnimating
            self.timeSinceRoleChange = 0
            self.preferredMode = .cached
        }
    }

    // MARK: - Rendering Decision

    /// Decision on how to render a character
    public enum RenderingDecision {
        case full3D  // Render full 3D model
        case cached  // Use cached sprite
        case skip  // Don't render (offscreen)
    }

    // MARK: - Performance Budget

    /// GPU performance budget configuration
    public struct PerformanceBudget {
        /// Target frame time in milliseconds (16.6ms = 60 FPS)
        public var targetFrameTimeMs: Float = 16.6

        /// Maximum number of full 3D characters
        public var maxFull3DCharacters: Int = 3

        /// Budget allocation for main speaker (ms)
        public var mainSpeakerBudgetMs: Float = 8.0

        /// Budget per listener (ms)
        public var listenerBudgetMs: Float = 4.0

        /// Budget for all sprites combined (ms)
        public var spriteBudgetMs: Float = 4.0

        /// Distance thresholds for LOD (near, medium, far)
        public var lodDistances: [Float] = [5.0, 10.0, 20.0]

        public init() {}
    }

    // MARK: - Properties

    /// All characters in the scene
    private var characters: [String: CharacterState] = [:]

    /// Performance budget
    public var budget: PerformanceBudget

    /// Role change hysteresis (prevent flickering between modes)
    public var roleChangeHysteresisMs: TimeInterval = 200  // 200ms

    /// Enable distance-based LOD
    public var enableDistanceLOD: Bool = true

    // MARK: - Initialization

    public init(budget: PerformanceBudget = PerformanceBudget()) {
        self.budget = budget
    }

    // MARK: - Character Management

    /// Register a character in the scene
    public func registerCharacter(
        characterID: String,
        displayName: String,
        position: SIMD3<Float> = SIMD3<Float>(0, 0, 0)
    ) {
        characters[characterID] = CharacterState(
            characterID: characterID,
            displayName: displayName,
            position: position
        )
        vrmLog("[CharacterPriority] Registered character '\(displayName)' (ID: \(characterID))")
    }

    /// Unregister a character
    public func unregisterCharacter(characterID: String) {
        characters.removeValue(forKey: characterID)
        vrmLog("[CharacterPriority] Unregistered character (ID: \(characterID))")
    }

    /// Update character role
    public func updateCharacterRole(characterID: String, role: CharacterRole) {
        guard var character = characters[characterID] else {
            vrmLog("[CharacterPriority] Warning: Character '\(characterID)' not registered")
            return
        }

        if character.role != role {
            character.role = role
            character.timeSinceRoleChange = 0
            characters[characterID] = character
            vrmLog("[CharacterPriority] Updated '\(character.displayName)' role to \(role)")
        }
    }

    /// Update character position
    public func updateCharacterPosition(characterID: String, position: SIMD3<Float>) {
        guard var character = characters[characterID] else { return }
        character.position = position
        characters[characterID] = character
    }

    /// Update character animation state
    public func updateCharacterAnimating(characterID: String, isAnimating: Bool) {
        guard var character = characters[characterID] else { return }
        character.isAnimating = isAnimating
        characters[characterID] = character
    }

    // MARK: - Priority Computation

    /// Compute rendering decisions for all characters
    public func computeRenderingDecisions(
        cameraPosition: SIMD3<Float>,
        deltaTime: TimeInterval
    ) -> [String: RenderingDecision] {
        var decisions: [String: RenderingDecision] = [:]

        // Update distances from camera
        updateDistancesFromCamera(cameraPosition)

        // Update hysteresis timers
        updateHysteresis(deltaTime: deltaTime)

        // Sort characters by priority
        let sortedCharacters = sortByPriority()

        // Allocate rendering slots
        var full3DCount = 0

        for character in sortedCharacters {
            let decision = determineRenderingMode(
                character: character,
                full3DCount: full3DCount
            )

            decisions[character.characterID] = decision

            if decision == .full3D {
                full3DCount += 1
            }

            // Update preferred mode
            if var updatedChar = characters[character.characterID] {
                updatedChar.preferredMode = decision
                characters[character.characterID] = updatedChar
            }
        }

        return decisions
    }

    /// Update distances from camera for all characters
    private func updateDistancesFromCamera(_ cameraPosition: SIMD3<Float>) {
        for (id, var character) in characters {
            let distance = simd_distance(character.position, cameraPosition)
            character.distanceFromCamera = distance
            characters[id] = character
        }
    }

    /// Update hysteresis timers
    private func updateHysteresis(deltaTime: TimeInterval) {
        for (id, var character) in characters {
            character.timeSinceRoleChange += deltaTime
            characters[id] = character
        }
    }

    /// Sort characters by priority (highest first)
    private func sortByPriority() -> [CharacterState] {
        return characters.values.sorted { char1, char2 in
            // Priority order: mainSpeaker > listener > background > offscreen
            let priority1 = rolePriority(char1.role)
            let priority2 = rolePriority(char2.role)

            if priority1 != priority2 {
                return priority1 > priority2
            }

            // If same priority, prefer closer characters
            return char1.distanceFromCamera < char2.distanceFromCamera
        }
    }

    /// Get priority score for a role (higher = more important)
    private func rolePriority(_ role: CharacterRole) -> Int {
        switch role {
        case .mainSpeaker: return 100
        case .listener: return 50
        case .background: return 10
        case .offscreen: return 0
        }
    }

    /// Determine rendering mode for a character
    private func determineRenderingMode(
        character: CharacterState,
        full3DCount: Int
    ) -> RenderingDecision {
        // Offscreen characters are skipped
        if character.role == .offscreen {
            return .skip
        }

        // Main speaker always gets full 3D (highest priority)
        if character.role == .mainSpeaker {
            return .full3D
        }

        // Check if we're over budget for full 3D
        if full3DCount >= budget.maxFull3DCharacters {
            return .cached
        }

        // Listeners get full 3D if budget allows
        if character.role == .listener {
            // Apply hysteresis: don't change mode too quickly
            if character.timeSinceRoleChange < roleChangeHysteresisMs / 1000.0 {
                return character.preferredMode
            }
            return .full3D
        }

        // Distance-based LOD for background characters
        if enableDistanceLOD {
            if character.distanceFromCamera < budget.lodDistances[0] {
                // Very close background characters can be full 3D if budget allows
                return .full3D
            }
        }

        // Default: use cached sprite
        return .cached
    }

    // MARK: - Statistics

    /// Get current priority statistics
    public func getStatistics() -> PriorityStatistics {
        let decisions = computeRenderingDecisions(
            cameraPosition: SIMD3<Float>(0, 0, 5),  // Dummy position
            deltaTime: 0
        )

        let full3DCount = decisions.values.filter { $0 == .full3D }.count
        let cachedCount = decisions.values.filter { $0 == .cached }.count
        let skippedCount = decisions.values.filter { $0 == .skip }.count

        return PriorityStatistics(
            totalCharacters: characters.count,
            full3DCharacters: full3DCount,
            cachedCharacters: cachedCount,
            skippedCharacters: skippedCount
        )
    }

    /// Priority statistics snapshot
    public struct PriorityStatistics {
        public let totalCharacters: Int
        public let full3DCharacters: Int
        public let cachedCharacters: Int
        public let skippedCharacters: Int

        public var description: String {
            return """
                Character Priority Statistics:
                  Total: \(totalCharacters)
                  Full 3D: \(full3DCharacters)
                  Cached: \(cachedCharacters)
                  Skipped: \(skippedCharacters)
                """
        }
    }

    // MARK: - Scene Presets

    /// Apply a dialogue scene preset
    /// - Parameters:
    ///   - mainSpeakerID: ID of main speaker
    ///   - listenerIDs: IDs of active listeners
    public func applyDialoguePreset(
        mainSpeakerID: String,
        listenerIDs: [String] = []
    ) {
        // Set all to background first
        for id in characters.keys {
            updateCharacterRole(characterID: id, role: .background)
        }

        // Set main speaker
        updateCharacterRole(characterID: mainSpeakerID, role: .mainSpeaker)

        // Set listeners
        for listenerID in listenerIDs {
            updateCharacterRole(characterID: listenerID, role: .listener)
        }

        vrmLog(
            "[CharacterPriority] Applied dialogue preset: speaker=\(mainSpeakerID), listeners=\(listenerIDs)"
        )
    }

    /// Apply a crowd scene preset (all cached except closest)
    /// - Parameter cameraPosition: Camera position for distance sorting
    public func applyCrowdPreset(cameraPosition: SIMD3<Float>) {
        updateDistancesFromCamera(cameraPosition)

        let sortedByDistance = characters.values.sorted {
            $0.distanceFromCamera < $1.distanceFromCamera
        }

        // Closest character is main speaker
        if let closest = sortedByDistance.first {
            updateCharacterRole(characterID: closest.characterID, role: .mainSpeaker)
        }

        // Next 2 are listeners
        for character in sortedByDistance.dropFirst().prefix(2) {
            updateCharacterRole(characterID: character.characterID, role: .listener)
        }

        // Rest are background
        for character in sortedByDistance.dropFirst(3) {
            updateCharacterRole(characterID: character.characterID, role: .background)
        }

        vrmLog("[CharacterPriority] Applied crowd preset")
    }
}
