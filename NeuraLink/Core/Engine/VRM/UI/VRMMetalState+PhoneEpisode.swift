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
    /// The clip lowers the arm over its last second; the phone goes away as
    /// that starts, and the body hands back just before the clip's end so
    /// it never shows the loop seam — the clip plays once.
    private static let phoneEpisodeLowerLead: Float = 1.1

    // MARK: - The phone itself

    static let phonePropName = "mobile_phone"
    /// A 15 cm object never needs the 4096² maps the file ships.
    static let phonePropTextureCap = 1024
    /// Materials whose picture is painted upside down relative to the body.
    /// None for this file: the picture only looked inverted while the body
    /// itself was held the wrong way round.
    static let phonePropUpsideDownTextureMaterials: Set<String> = []

    /// Where the phone sits in the right hand, in the VRM 1.0 hand frame
    /// (T-pose: fingers −X, thumb +Z, palm −Y). Derived by
    /// CheckingPhoneClipDiagnostic at the clip's hold pose: SHE is reading
    /// it, so the screen (the file's −Z after the loader's chain; +Z carries
    /// the camera module) faces up and back into her eyes and the top of the
    /// phone (the file's −Y end — +Y runs toward the bottom) leans 45° away
    /// from her toward the viewer, who sees its back. Rolled about 12°
    /// toward the fingertips, the back resting on the upturned palm — centre
    /// just above the palm's centre, 1 cm toward the screen side — the fist
    /// closed around its lower half. 85% of life size. Re-run the diagnostic
    /// to re-derive if the clip or the prop file changes; it renders derived
    /// vs shipped from both cameras, and NL_PHONE_GRIP_VARIANTS renders
    /// refinement variants.
    static let phoneGrip = VRMPropGrip(
        translation: SIMD3<Float>(-0.037, -0.011, 0.010),
        rotation: simd_quatf(ix: -0.5507, iy: -0.3996, iz: -0.1957, r: 0.7062),
        scale: 0.85)

    /// Loads the phone GLB once, off the main thread, and attaches it to
    /// whatever character is on screen by the time it is in.
    func loadPhoneProp() {
        guard phoneProp == nil, let device = mtkView.device,
            let url = Bundle.main.url(forResource: Self.phonePropName, withExtension: "glb")
        else { return }
        Task.detached(priority: .utility) { [weak self] in
            do {
                let prop = try await VRMPropLoader.load(
                    url: url, device: device, maxTextureSize: Self.phonePropTextureCap,
                    rotatedMaterials: Self.phonePropUpsideDownTextureMaterials)
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
            let duration = phoneEpisodeClip?.duration ?? .greatestFiniteMagnitude
            // Once is enough: when the clip has played through, the episode
            // is over even if the spoken result is still going.
            if phoneEpisodeClipElapsed >= duration - Self.phoneEpisodeCrossfade {
                nlLog("[PhoneEpisode] clip finished")
                endPhoneEpisode()
                PhoneEpisode.end(reason: "clip finished")
                return
            }
            // The hand reaches the pose over the crossfade and lowers over the
            // last second; the phone is in it only in between.
            let holding = phoneEpisodeClipElapsed >= Self.phoneEpisodeCrossfade
                && phoneEpisodeClipElapsed < duration - Self.phoneEpisodeLowerLead
            setPhonePropVisible(holding)
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
