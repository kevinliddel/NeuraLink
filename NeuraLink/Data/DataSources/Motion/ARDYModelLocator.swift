//
//  ARDYModelLocator.swift
//  NeuraLink
//
//  Where the ARDY-mini files are on this device: the verified download in
//  the asset cache (MotionModelAccess), else a folder in Caches with the
//  standard names, which the motion bench and development fill by hand.
//  docs/REALTIME_MOTION_PLAN.md, Phases 4 and 5.
//
//  Created by Dedicatus on 30/10/2026.
//

import Foundation

enum ARDYModelLocator {
    static let developmentFolderName = "ardy-mini-fp32"

    /// The development folder in Caches, present or not.
    nonisolated static var developmentDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(developmentFolderName, isDirectory: true)
    }

    /// True when a complete model is on the device, downloaded or hand-copied.
    nonisolated static var isComplete: Bool {
        MotionModelAccess.isDownloaded || ARDYModelFiles(directory: developmentDirectory).isComplete
    }

    /// The files to load, downloaded copy first.
    static func files() async -> ARDYModelFiles? {
        if let downloaded = await MotionModelAccess.downloadedFiles() { return downloaded }
        let development = ARDYModelFiles(directory: developmentDirectory)
        return development.isComplete ? development : nil
    }
}
