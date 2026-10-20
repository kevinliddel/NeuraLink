//
//  AnimationCatalogue.swift
//  NeuraLink
//
//  Which bundled clips a character's body draws on. The entrance, the
//  talking gestures and the episode clips (phone, listening) are shared by
//  every character. The base idle, the random idles, the resting loop and
//  the photo poses are picked by CharacterGender: the female set is the
//  original library, the male set came over from the Sonya project
//  (prefixed `male_`), and a feminine pose asked of a male character is
//  swapped for a shared one rather than refused.
//
//  Framework-free and unit-tested; VRMMetalState reads it at load time.
//
//  Created by Dedicatus on 20/10/2026.
//

import Foundation

nonisolated enum AnimationCatalogue {

    // MARK: - Shared

    static let appear = "appear"

    /// Everything that plays regardless of gender, for the bundle check.
    static let sharedClipNames = [
        appear, "speaking", "talking", "checking_phone", "listen_to_music"
    ]

    // MARK: - Per gender

    /// The loop the body rests in between everything else.
    static func neutralClipName(for gender: CharacterGender) -> String {
        switch gender {
        case .female: return "neutral"
        case .male: return "male_breathing"
        }
    }

    /// The random idle pool, played once each between stretches of the
    /// base loop. The female resting loop is part of it on purpose: it is
    /// an ordinary idle as well as the away episode's clip.
    static func idleClipNames(for gender: CharacterGender) -> [String] {
        switch gender {
        case .female:
            return ["default_state", "neutral_2", "neutral_3", "neutral_4", "relax", "waiting"]
        case .male:
            return ["male_look_around", "male_powerful", "male_stretching_arms", "neutral_4"]
        }
    }

    /// The loop the away episode rests in (docs/LIVING_COMPANION.md). His
    /// base loop is already a quiet breathing stand, so he rests in it.
    static func awayClipName(for gender: CharacterGender) -> String {
        switch gender {
        case .female: return AwayEpisodePolicy.clipName
        case .male: return neutralClipName(for: .male)
        }
    }

    /// Photo poses the model may ask for; the tool offers these names to
    /// both genders and the body resolves them here.
    static let poseNames = ["cool", "peace_sign", "relax", "stretch"]

    /// The clip a pose plays on a body of this gender. The two feminine
    /// poses map to the shared ones; `cool` and `stretch` fit everyone.
    static func poseClipName(_ pose: String, for gender: CharacterGender) -> String {
        guard gender == .male else { return pose }
        switch pose {
        case "peace_sign": return "cool"
        case "relax": return "stretch"
        default: return pose
        }
    }

    /// Every clip name a body of this gender may ever load.
    static func allClipNames(for gender: CharacterGender) -> [String] {
        var names = sharedClipNames + [neutralClipName(for: gender)] + idleClipNames(for: gender)
        names += [awayClipName(for: gender)] + poseNames.map { poseClipName($0, for: gender) }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }
}
