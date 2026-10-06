//
//  VRMMetalState+PhoneEpisode.swift
//  NeuraLink
//
//  Body side of the phone episode (PhoneEpisode.swift): on begin the
//  character crossfades into the looping checking_phone clip with gaze
//  tracking off and owns the body — idles, talking gestures and look-back
//  wait — until the end signal or the safety cap hands it back to neutral.
//
//  Created by Dedicatus on 06/10/2026.
//

import Foundation
import MetalKit
import simd

extension VRMMetalState {

    private static let phoneEpisodeCrossfade: Float = 0.5

    // MARK: - The phone itself

    static let phonePropName = "mobile_phone"
    /// A 15 cm object never needs the 4096² maps the file ships.
    static let phonePropTextureCap = 1024

    /// Where the phone sits in the right hand, in the VRM 1.0 hand frame
    /// (T-pose: fingers −X, thumb +Z, palm −Y). A texting grip: the long
    /// axis runs along the thumb's direction so the phone sticks up past
    /// the thumb toward the face, the fingers wrap around its width, the
    /// screen faces the palm's way and so meets the eyes when the clip turns
    /// the palm up. The file's +Y long axis / +Z screen become +Z / −Y with
    /// one +90° turn about X; the centre sits just off the palm, between
    /// the finger bases and the thumb.
    static let phoneGrip = VRMPropGrip(
        translation: SIMD3<Float>(-0.035, -0.015, 0.03),
        rotation: simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0)))

    /// Loads the phone GLB once, off the main thread, and attaches it to
    /// whatever character is on screen by the time it is in.
    func loadPhoneProp() {
        guard phoneProp == nil, let device = mtkView.device,
            let url = Bundle.main.url(forResource: Self.phonePropName, withExtension: "glb")
        else { return }
        Task.detached(priority: .utility) { [weak self] in
            do {
                let prop = try await VRMPropLoader.load(url: url, device: device, maxTextureSize: Self.phonePropTextureCap)
                await MainActor.run {
                    guard let self else { return }
                    self.phoneProp = prop
                    if let model = self.currentModel { self.attachPhoneProp(to: model) }
                }
            } catch {
                nlLog("[PhoneEpisode] ⚠️ phone prop failed to load: \(error)", level: .warning)
            }
        }
    }

    /// Hangs the (hidden) phone off the character's right hand. No-op until
    /// the prop has loaded or when this character already has it.
    func attachPhoneProp(to model: VRMModel) {
        guard let prop = phoneProp, phonePropAttachment == nil else { return }
        do {
            phonePropAttachment = try model.attachProp(prop, to: .rightHand, grip: Self.phoneGrip)
            renderer?.invalidateRenderItems()
            nlLog("[PhoneEpisode] phone attached to \(VRMHumanoidBone.rightHand.rawValue) (hidden)")
        } catch {
            nlLog("[PhoneEpisode] ⚠️ phone could not be attached: \(error)", level: .warning)
        }
    }

    func setPhonePropVisible(_ visible: Bool) {
        guard let model = currentModel, let attachment = phonePropAttachment, attachment.isVisible != visible else { return }
        model.setProp(attachment, visible: visible)
        renderer?.invalidateRenderItems()
        nlLog("[PhoneEpisode] phone \(visible ? "in hand" : "put away")")
    }

    // MARK: - Episode

    func setupPhoneEpisodeObservers() {
        NotificationCenter.default.addObserver(forName: PhoneEpisode.didBegin, object: nil, queue: .main) { [weak self] _ in
            self?.beginPhoneEpisode()
        }
        NotificationCenter.default.addObserver(forName: PhoneEpisode.didEnd, object: nil, queue: .main) { [weak self] _ in
            self?.endPhoneEpisode()
        }
    }

    /// Takes the body for the episode. Gaze goes off right away — the clip
    /// tilts the head toward the hand and look-at would overwrite it. The
    /// clip starts now if the body is free; otherwise `updatePhoneEpisode`
    /// starts it once the entrance clip or a pose has finished.
    func beginPhoneEpisode() {
        guard phoneEpisode.begin() else { return }
        renderer?.lookAtController?.enabled = false
        startPhoneEpisodeClipIfPossible()
    }

    /// Hands the body back: gaze on, crossfade to neutral, idles re-armed.
    func endPhoneEpisode() {
        guard phoneEpisode.end() else { return }
        setPhonePropVisible(false)
        renderer?.lookAtController?.enabled = true
        let wasPlaying = isPlayingPhoneEpisodeClip
        isPlayingPhoneEpisodeClip = false
        guard wasPlaying, let model = currentModel, let clip = defaultClip, !isPlayingPose else { return }
        animationPlayer.isLooping = true
        animationPlayer.crossfade(to: clip, duration: Self.phoneEpisodeCrossfade, from: model)
        scheduleNextRandomAnim()
        nlLog("[PhoneEpisode] ↩ neutral")
    }

    /// Per frame while active: start the clip once the body frees up, and
    /// enforce the safety cap so a lost stop can never freeze her mid-call.
    func updatePhoneEpisode(dt: Float) {
        guard phoneEpisode.isActive else { return }
        if phoneEpisode.tick(dt: dt) {
            nlLog("[PhoneEpisode] expired after \(Int(phoneEpisode.maxHold))s without a stop", level: .info)
            endPhoneEpisode()
            PhoneEpisode.end(reason: "safety cap")
            return
        }
        if isPlayingPhoneEpisodeClip {
            phoneEpisodeClipElapsed += dt
            // The hand reaches the pose over the crossfade; the phone appears
            // once it is there rather than popping into a hand at her side.
            if phoneEpisodeClipElapsed >= Self.phoneEpisodeCrossfade { setPhonePropVisible(true) }
        } else {
            setPhonePropVisible(false)  // a pose took the body, or the clip has not started
            startPhoneEpisodeClipIfPossible()
        }
    }

    private func startPhoneEpisodeClipIfPossible() {
        guard let model = currentModel, let clip = phoneEpisodeClip, !isPlayingAppear, !isPlayingPose else { return }
        isPlayingPhoneEpisodeClip = true
        phoneEpisodeClipElapsed = 0
        isPlayingRandomAnim = false
        randomAnimElapsed = 0
        randomAnimTimer = -1  // idles wait until the episode hands back
        isPlayingTalkingGesture = false
        animationPlayer.isLooping = true
        animationPlayer.crossfade(to: clip, duration: Self.phoneEpisodeCrossfade, from: model)
        nlLog("[PhoneEpisode] ▶ \(PhoneEpisodePolicy.clipName)")
    }
}
