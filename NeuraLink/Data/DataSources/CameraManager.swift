//
//  CameraManager.swift
//  NeuraLink
//
//  Manages the AVCaptureSession lifecycle and provides on-demand
//  frame snapshots for the AI vision tool.
//

import AVFoundation
import Foundation
import UIKit

@Observable
final class CameraManager: NSObject, @unchecked Sendable {

    static let shared = CameraManager()

    // MARK: - Observed state

    var isActive = false
    var permissionGranted = false
    var cameraPosition: AVCaptureDevice.Position = .front

    // MARK: - Internal (not observed)

    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private let videoOutput = AVCaptureVideoDataOutput()
    @ObservationIgnored private let sessionQueue = DispatchQueue(
        label: "com.neuralink.camera.session", qos: .userInitiated)
    @ObservationIgnored private let ciContext = CIContext()
    // Written via Task { @MainActor }; read only from MainActor (AppFunctionExecutor).
    @ObservationIgnored private var latestPixelBuffer: CVPixelBuffer?

    private override init() {
        super.init()
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
    }

    // MARK: - Public API

    func requestPermissionAndStart() async {
        let granted = await resolvePermission()
        await MainActor.run { permissionGranted = granted }
        guard granted else { return }

        sessionQueue.async { [weak self] in
            self?.configureSession(position: .front)
            self?.session.startRunning()
            Task { @MainActor [weak self] in self?.isActive = true }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
            Task { @MainActor [weak self] in self?.isActive = false }
        }
    }

    func switchCamera() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let newPosition: AVCaptureDevice.Position = self.cameraPosition == .front ? .back : .front
            self.session.beginConfiguration()
            self.session.inputs.forEach { self.session.removeInput($0) }
            self.addCameraInput(position: newPosition)
            self.session.commitConfiguration()
            Task { @MainActor [weak self] in self?.cameraPosition = newPosition }
        }
    }

    /// Captures a single frame from the latest camera buffer. Call on MainActor.
    @MainActor
    func captureCurrentFrame() -> UIImage? {
        guard let pixelBuffer = latestPixelBuffer else { return nil }
        let ciImage = CIImage(cvImageBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cgImage, scale: 1.0, orientation: .right)
    }

    // MARK: - Private

    private func resolvePermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            return false
        }
    }

    private func configureSession(position: AVCaptureDevice.Position) {
        session.beginConfiguration()
        session.sessionPreset = .medium
        addCameraInput(position: position)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
        session.commitConfiguration()
    }

    private func addCameraInput(position: AVCaptureDevice.Position) {
        guard
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else { return }
        session.addInput(input)
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        Task { @MainActor [weak self] in self?.latestPixelBuffer = pixelBuffer }
    }
}
