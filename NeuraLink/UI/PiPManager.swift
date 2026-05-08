//
//  PiPManager.swift
//  NeuraLink
//

import AVKit
import SwiftUI
import Combine
import MetalKit
import UIKit

@MainActor
final class PiPManager: NSObject, ObservableObject, AVPictureInPictureControllerDelegate {
    static let shared = PiPManager()

    @Published var isPiPActive = false
    @Published var canStartPiP = false
    
    // We allow auto PiP if enabled in settings, but default to true here
    @Published var isAutoPiPEnabled = true

    private var pipController: AVPictureInPictureController?
    private var pipVideoCallViewController: AVPictureInPictureVideoCallViewController?
    
    weak var mtkView: MTKView?
    private weak var originalSuperview: UIView?
    private var cancellables = Set<AnyCancellable>()

    override private init() {
        super.init()
        setupAudioSession()
    }

    private func setupAudioSession() {
        // PiP requires an active audio session. Since we use VAD/TTS, this is likely already
        // configured, but we ensure it is ready for playback so PiP doesn't fail.
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker])
            try session.setActive(true)
        } catch {
            print("[PiPManager] Failed to set audio session for PiP: \(error)")
        }
    }

    func setupPiP(sourceView: UIView, mtkView: MTKView) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        if #available(iOS 15.0, *) {
            self.mtkView = mtkView
            let pipVC = AVPictureInPictureVideoCallViewController()
            pipVC.preferredContentSize = CGSize(width: 300, height: 400)
            self.pipVideoCallViewController = pipVC

            let contentSource = AVPictureInPictureController.ContentSource(
                activeVideoCallSourceView: sourceView,
                contentViewController: pipVC
            )
            
            let pipController = AVPictureInPictureController(contentSource: contentSource)
            pipController.delegate = self
            pipController.canStartPictureInPictureAutomaticallyFromInline = isAutoPiPEnabled
            self.pipController = pipController
            
            self.canStartPiP = pipController.isPictureInPicturePossible
            
            pipController.publisher(for: \.isPictureInPicturePossible)
                .sink { [weak self] isPossible in
                    self?.canStartPiP = isPossible
                }
                .store(in: &cancellables)
        }
    }

    func startPiP() {
        pipController?.startPictureInPicture()
    }

    func stopPiP() {
        pipController?.stopPictureInPicture()
    }

    // MARK: - AVPictureInPictureControllerDelegate

    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isPiPActive = true
        guard let mtkView = mtkView else { return }
        
        if #available(iOS 15.0, *) {
            guard let pipView = pipVideoCallViewController?.view else { return }
            originalSuperview = mtkView.superview
            
            mtkView.alpha = 0
            pipView.addSubview(mtkView)
            mtkView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                mtkView.leadingAnchor.constraint(equalTo: pipView.leadingAnchor),
                mtkView.trailingAnchor.constraint(equalTo: pipView.trailingAnchor),
                mtkView.topAnchor.constraint(equalTo: pipView.topAnchor),
                mtkView.bottomAnchor.constraint(equalTo: pipView.bottomAnchor)
            ])
            
            UIView.animate(withDuration: 0.3) {
                mtkView.alpha = 1
            }
        }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isPiPActive = false
        guard let mtkView = mtkView, let originalSuperview = originalSuperview else { return }
        
        mtkView.alpha = 0
        originalSuperview.addSubview(mtkView)
        mtkView.translatesAutoresizingMaskIntoConstraints = true
        mtkView.frame = originalSuperview.bounds
        mtkView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        
        UIView.animate(withDuration: 0.5, delay: 0.1, options: .curveEaseInOut) {
            mtkView.alpha = 1
        }
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        // Signal that the UI is ready for the transition
        completionHandler(true)
    }
}
