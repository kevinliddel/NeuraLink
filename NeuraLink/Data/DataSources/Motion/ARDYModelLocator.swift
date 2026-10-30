//
//  ARDYModelLocator.swift
//  NeuraLink
//
//  Where the ARDY-mini files live on the device: model.json, the three
//  ONNX graphs and the tokenizer, in Caches, the folder the motion bench
//  also fills. Phase 5 adds the pinned download; until then the folder is
//  filled by the bench or by hand. docs/REALTIME_MOTION_PLAN.md, Phase 4.
//
//  Created by Dedicatus on 30/10/2026.
//

import Foundation

enum ARDYModelLocator {
    static let folderName = "ardy-mini-fp32"
    static let requiredFiles = ["model.json", "text_encoder.onnx", "denoiser.onnx", "decoder.onnx", "tokenizer/tokenizer.json", "tokenizer/tokenizer_config.json"]

    /// The model folder in Caches, present or not.
    nonisolated static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(folderName, isDirectory: true)
    }

    /// True when every required file is there.
    nonisolated static var isComplete: Bool {
        let dir = directory
        return requiredFiles.allSatisfy { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }
}
