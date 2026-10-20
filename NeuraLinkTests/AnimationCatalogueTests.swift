//
//  AnimationCatalogueTests.swift
//  NeuraLinkTests
//
//  The gendered clip pools: a base loop each, distinct idle sets, a resting
//  loop the body already knows, feminine poses swapped for shared ones, and
//  every named clip present in the bundle and loadable on the male character.
//
//  Created by Dedicatus on 20/10/2026.
//

import Foundation
import Metal
import Testing
@testable import NeuraLink

@Suite("Animation catalogue")
struct AnimationCatalogueTests {

    @Test("Each gender has its own base loop and idle pool, and rests in a clip it already holds")
    func poolsPerGender() {
        #expect(AnimationCatalogue.neutralClipName(for: .female) == "neutral")
        #expect(AnimationCatalogue.neutralClipName(for: .male) == "male_breathing")

        let female = Set(AnimationCatalogue.idleClipNames(for: .female))
        let male = Set(AnimationCatalogue.idleClipNames(for: .male))
        #expect(!female.isEmpty && !male.isEmpty)
        // A male idle is one of his own clips, or a gender-neutral idle the
        // female pool shares (neutral_4) — never a feminine-only clip.
        for name in male {
            #expect(name.hasPrefix("male_") || female.contains(name), "\(name) is neither a male clip nor a shared idle")
        }
        #expect(female.allSatisfy { !$0.hasPrefix("male_") })
        #expect(male.contains { $0.hasPrefix("male_") }, "he has at least one clip of his own")
        #expect(!male.contains(AnimationCatalogue.neutralClipName(for: .male)), "the base loop is not an idle")

        for gender in CharacterGender.allCases {
            let known = Set(AnimationCatalogue.idleClipNames(for: gender)) .union([AnimationCatalogue.neutralClipName(for: gender)])
            #expect(known.contains(AnimationCatalogue.awayClipName(for: gender)), "\(gender)")
        }
        #expect(AnimationCatalogue.awayClipName(for: .female) == AwayEpisodePolicy.clipName)
    }

    @Test("A feminine pose on a male body becomes a shared one; the rest stay")
    func posesResolvePerGender() {
        for pose in AnimationCatalogue.poseNames {
            #expect(AnimationCatalogue.poseClipName(pose, for: .female) == pose)
        }
        #expect(AnimationCatalogue.poseClipName("peace_sign", for: .male) == "cool")
        #expect(AnimationCatalogue.poseClipName("relax", for: .male) == "stretch")
        #expect(AnimationCatalogue.poseClipName("cool", for: .male) == "cool")
        #expect(AnimationCatalogue.poseClipName("stretch", for: .male) == "stretch")
        #expect(AnimationCatalogue.poseNames == PhotoshootSkill.availablePoses)
    }

    @Test("Every clip a body may load ships in the bundle", arguments: CharacterGender.allCases)
    func clipsShip(gender: CharacterGender) {
        // Unit-only builds may not package the animations at all.
        guard Bundle.main.url(forResource: "neutral", withExtension: "vrma") != nil else { return }
        for name in AnimationCatalogue.allClipNames(for: gender) {
            #expect(Bundle.main.url(forResource: name, withExtension: "vrma") != nil, "\(name).vrma")
        }
    }

    @Test("The male base loop and idles retarget onto Oz with real motion")
    @MainActor
    func maleClipsLoadOnOz() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let modelURL = Bundle.main.url(forResource: "Oz", withExtension: "vrm")
        else { return }
        let model = try await VRMModel.load(from: modelURL, device: device)
        let names = [AnimationCatalogue.neutralClipName(for: .male)] + AnimationCatalogue.idleClipNames(for: .male)
        for name in names {
            let url = try #require(Bundle.main.url(forResource: name, withExtension: "vrma"), "\(name).vrma")
            let clip = try await VRMAnimationLoader.loadVRMA(from: url, model: model)
            #expect(clip.duration > 1, "\(name) lasts \(clip.duration)s")
        }
    }
}
