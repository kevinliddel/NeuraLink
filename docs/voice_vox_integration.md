# VOICEVOX Local TTS Integration Plan

This document outlines the technical feasibility and implementation strategy for integrating the **VOICEVOX** text-to-speech engine into NeuraLink.

## 1. Overview
VOICEVOX is a high-quality, neural-network-based Japanese TTS engine. By integrating `voicevox_core`, NeuraLink will provide expressive, character-specific voices for offline AI interactions, significantly enhancing the "local companion" experience.

## 2. Technical Feasibility
The integration is feasible using the official `voicevox_core` iOS build artifacts.

### 2.1 Requirements
- **Library**: `voicevox_core.xcframework` (arm64 for iOS devices).
- **Dependency**: `onnxruntime.xcframework` (execution provider for neural inference).
- **Resources**:
  - `open_jtalk_dic_utf_8-1.11`: Required for linguistic analysis.
  - `.vvm` files: Character-specific model weights.
- **Hardware**: Best performance achieved on A13 Bionic (iPhone 11) and newer via Apple Neural Engine (ANE).

### 2.2 Integration Points
| Layer | Responsibility |
|---|---|
| **Storage** | `VoiceVoxModelManager` handles downloading and caching of `.vvm` model files. |
| **Engine** | `VoiceVoxEngine` (conforming to `TTSEngineProtocol`) manages the core initialization and synthesis. |
| **Settings** | `PersonaSettingsView` updated to include "VOICEVOX" as a provider with character/style selection. |
| **Audio** | Generated PCM data is routed through the existing `AudioEngine` for spatial playback. |

## 3. Implementation Phases

### Phase 1: Dependency Integration
1. Add `voicevox_core.xcframework` and `onnxruntime.xcframework` to the project.
2. Bundle the standard Open JTalk dictionary in the App Bundle.
3. Establish a `VoiceVoxBridge.h` if needed for custom C API interactions.

### Phase 2: Core Engine
1. Implement `VoiceVoxEngine` to handle initialization with dictionary and model paths.
2. Implement asynchronous synthesis to prevent UI blocking during inference.
3. Map VOICEVOX characters (Speaker IDs) to NeuraLink `CharacterPersona` profiles.

### Phase 3: UI & Persona Persistence
1. Add VOICEVOX character selection UI to `AISettingsView`.
2. Persist chosen Speaker IDs in the `PersonaStore`.
3. Add "Play Sample" functionality in the settings menu.

## 4. Compliance & Licensing
- **Code**: `voicevox_core` is MIT Licensed.
- **Voices**: Each VOICEVOX character has specific usage terms (typically requiring attribution: "VOICEVOX: CharacterName").
- **Storage**: Model files (~20-50MB per character) will be downloaded on-demand to keep the initial app size small.

## 5. Performance Targets
- **Inference Latency**: < 500ms for short sentences on A14+ chips.
- **Memory Footprint**: ~150-200MB during active synthesis.
- **Battery Impact**: Minimized by leveraging NPU/ANE via ONNX Runtime.
