# Local Voice Cloning Implementation Plan (F5-TTS + MLX-Swift)

## Overview
This document outlines the implementation of a zero-shot local voice cloning system for NeuraLink using **F5-TTS** and **MLX-Swift**. F5-TTS is a state-of-the-art flow-matching model that provides high-fidelity cloning with as little as 3 seconds of reference audio.

## 1. Principles (Reference: `rule.md`)
- **Modularity:** Abstract TTS logic into a dedicated `F5TTSEngine`.
- **Clean Architecture:** Use the `TTSProtocol` to switch between system and custom engines.
- **Performance:** Utilize **MLX** for native GPU/ANE acceleration, crucial for the diffusion-based inference of F5-TTS.

## 2. Technology Stack
- **Framework:** [MLX-Swift](https://github.com/ml-explore/mlx-swift) (Apple's official ML framework for Swift).
- **Core Engine:** **Inlined F5-TTS & Vocos** (Located in `NeuraLink/AI/TTS/InternalF5/`). This bypasses SPM versioning conflicts and allows native integration with the project's dependency graph.
- **Model Architecture:** DiT (Diffusion Transformer) for flow-matching and **Vocos** for high-fidelity vocoding.
- **Audio Processing:** `AVAudioEngine` for real-time playback and lip-sync analysis.

## 3. Data Strategy
- **Reference Samples:** 
  - `NeuraLink/riko.wav` (Zero-shot reference for Riko persona)
  - `NeuraLink/akira.mp3` (Zero-shot reference for Akira persona)
- **Local Model Files (Project Root):**
  - `model.safetensors`: The main F5-TTS Diffusion Transformer weights.
  - `vocab.txt`: Tokenizer mapping for text-to-phoneme conversion.
  - `vocos.safetensors`: Vocos vocoder weights for waveform synthesis.
- **Transcription:** Automated via `LocalWhisperManager`. Transcripts are cached to provide the identity-conditioning prefix required by the DiT model.

## 4. Implementation Status

### Phase 1: Infrastructure & Decoupling (DONE)
1.  **Extract TTS:** Moved `AVSpeechSynthesizer` logic into `SystemTTSEngine`.
2.  **Protocol Definition:** Defined `TTSProtocol`.

### Phase 2: F5-TTS Integration (DONE)
1.  **Inlining Logic:** Source code from `f5-tts-swift` and `vocos-swift` was inlined into `NeuraLink/AI/TTS/InternalF5/` to ensure full compatibility with `swift-transformers` 1.0.0+.
2.  **Actor Isolation:** Implemented `nonisolated` math modules to prevent blocking the MainActor during heavy diffusion inference.
3.  **Engine Implementation:** `F5TTSEngine.swift` handles the full pipeline: Whisper transcription -> DiT Inference -> Vocos Decoding -> PCM Buffer generation.

### Phase 3: Inference & Streaming
1.  **Flow-matching Inference:** Implement the ODE solver for the DiT model in Swift/MLX.
2.  **Vocoding:** Convert the generated mel-spectrogram into audio using a high-fidelity vocoder.
3.  **Streaming:** Use chunk-based diffusion to start playback before the full text is synthesized.

## 4. Implementation Steps (Original Plan)

### Phase 4: Audio Pipeline & Lip-Sync
1.  **PCM Conversion:** Convert MLX output arrays to `AVAudioPCMBuffer`.
2.  **Real-time Analysis:** Route audio through the mixer tap to drive VRM lip-sync.
