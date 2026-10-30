//
//  NLSignposts.swift
//  NeuraLink
//
//  Instruments signposts for the hot paths: LLM
//  prefill / generate, the Metal frame, and whisper transcription. Free
//  when no one is recording; in Instruments → os_signpost they show the
//  real frame time, time-to-first-token and transcription latency.
//
//  Created by Dedicatus on 19/10/2026.
//

import Foundation
import os

enum NLSignposts {
    static let subsystem = "com.dedicatus.NeuraLink"

    static let llm = OSSignposter(subsystem: subsystem, category: "LLM")
    static let render = OSSignposter(subsystem: subsystem, category: "Render")
    static let speech = OSSignposter(subsystem: subsystem, category: "Speech")
    /// Generated motion: text encoding, denoised windows, decoding.
    static let motion = OSSignposter(subsystem: subsystem, category: "Motion")
}
