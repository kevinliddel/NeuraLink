# NeuraLink

<p align="center">
    <img src="./docs/Models/Ekaterina.jpeg" alt="NeuraLink Model" width="400" />
</p>

<p align="center">
  <img src="https://img.shields.io/badge/iOS-17.0%2B-blue?style=flat&logo=apple" alt="iOS" />
  <img src="https://img.shields.io/badge/Swift-6.0-orange?style=flat&logo=swift" alt="Swift" />
  <img src="https://img.shields.io/badge/Graphics-Metal-brightgreen?style=flat&logo=metal" alt="Metal" />
  <img src="https://custom-icon-badges.demolab.com/badge/ChatGPT-74aa9c?logo=openai&logoColor=white" alt="OpenAI" />
  <img src="https://img.shields.io/badge/Hugging%20Face-FFD21E?logo=huggingface&logoColor=fff" alt="Hugging Face" />
  <img src="https://img.shields.io/badge/Ollama-fff?logo=ollama&logoColor=000" alt="Ollama" />
  <img src="https://img.shields.io/badge/WhisperKit-gray?logo=swift" alt="WhisperKit" />
  <img src="https://img.shields.io/badge/WebRTC-gray?style=flat&logo=webrtc" alt="WebRTC" />
  <img src="https://img.shields.io/badge/Silero-VAD-red?style=flat&logo=silero" alt="Silero VAD" />
</p>

A high-performance, native iOS VRM character viewer and AI companion built from the ground up using **Metal** and **SwiftUI**. NeuraLink connects to the OpenAI Realtime API via **WebSocket** with **AVAudioEngine** for mic capture and AI audio playback — fully screen-recordable and integrated with synchronized visual feedback.

---

## ✨ Features

- **Native Metal Engine**: Custom MToon shaders and GPU-accelerated rendering.
- **Spring-Bone Physics**: Real-time GPU compute for hair and clothing movement.
- **Neural Lip-Sync**: Real-time audio amplitude analysis mapped to VRM blend shapes.
- **Advanced Camera**: Orbit controls with look-at behavior following the viewing angle.
- **Universal Support**: Handles both VRM 0.x and 1.0 specifications.
- **Realtime sky system**: Real-time sky with realistic lighting with dynamic sun and moon positioning.
- **"Eyes on You" System**: Features an Arknights: Endfield-inspired camera system, where characters will maintain eye contact by turning their heads toward the camera if it remains behind them for more than 5 seconds.
- **Dual-Layer VAD**: Client-side Silero VAD (v5 model) runs alongside OpenAI's server VAD for instant local voice detection and immediate UI feedback.
- **Per-Character Personas**: Each character carries her own system prompt and voice model, hot-swapped on model selection.
- **NPU Ready**: Architecture planned for [Apple Neural Engine integration](./docs/npu.md) via Core ML and MLX to enable local VAD, offline speech-to-text, and local LLMs.


---

## 🌤️ Realtime Sky System

NeuraLink renders a fully procedural, physically-inspired sky backdrop that **automatically mirrors the user's local time of day** — from the cool darkness of midnight to the warm golden glow of an afternoon sun.

<p align="center">
  <img src="./docs/Environments/sunrise.jpeg" alt="Sunrise" width="180" style="margin:4px;" />
  <img src="./docs/Environments/afternoon-sun.jpeg" alt="Afternoon sun" width="180" style="margin:4px;" />
  <img src="./docs/Environments/sunset.jpeg" alt="Sunset" width="180" style="margin:4px;" />
  <img src="./docs/Environments/night.jpeg" alt="Night" width="180" style="margin:4px;" />
</p>

Key highlights:

- **Clock-driven** — `SkyTimeProvider` reads the device's local calendar every frame; no manual configuration required.
- **Procedural GPU shader** — a single fullscreen-triangle Metal draw call renders the gradient, star field, dual-layer dome clouds, sun disc with bloom, and a moon disc opposite the sun.
- **Unified lighting** — the resolved `SkyEnvironment` drives a three-point key / fill / rim light rig that keeps the VRM character consistently lit against the sky at every hour.
- **Zero textures** — all visual elements (clouds, stars, sun, moon) are generated procedurally via FBM noise and analytic functions.

**[Full Sky System documentation](./docs/Sky-System.md)**

---

## 🫆 VRM Specifications

NeuraLink follows the official **VRM ecosystem standards** to ensure compatibility, realism, and expressive avatars.

| Category | Specification |
|----------|---------------|
| **Core** | [VRM 1.0](https://github.com/vrm-c/vrm-specification/tree/master/specification/VRMC_vrm-1.0) • [VRM 0.x](https://github.com/vrm-c/vrm-specification/tree/master/specification/0.0) |
| **Materials**| [MToon 1.0](https://github.com/vrm-c/vrm-specification/tree/master/specification/VRMC_materials_mtoon-1.0) |
| **Physics**  | [Spring-Bone 1.0](https://github.com/vrm-c/vrm-specification/tree/master/specification/VRMC_springBone-1.0) |
| **Animation**| [VRM Animation 1.0](https://github.com/vrm-c/vrm-specification/tree/master/specification/VRMC_vrm_animation-1.0) |

## 🛠️ Architecture

### Real-time Audio & LipSync Pipeline

NeuraLink uses a high-efficiency dual-VAD pipeline to minimise latency between the user's voice and the AI's response.

```mermaid
graph TD
    MIC[Microphone]

    MIC --> WebRTC[WebRTC Audio Track]
    MIC --> Tap[AVAudioEngine Tap]

    subgraph VAD [Dual VAD Layer]
        Tap --> Silero[Silero VAD v5\nClient-side · Local]
        WebRTC --> ServerVAD[OpenAI Server VAD\nCloud · Turn-taking]
    end

    Silero --> VoiceEvent[voiceStarted / voiceEnded]
    VoiceEvent --> UIState[UI State\nlistening ↔ ready]
    ServerVAD --> Commit[commit]
    Commit --> API

    WebRTC --> API[OpenAI Realtime API\ngpt-realtime]
    API --> WebRTCLink[WebRTC]
    WebRTCLink --> RTC(RTCAudioSession)
    RTC --> Buffer[PCM Audio Buffer]
    Buffer --> Output[Speakers]
    Buffer --> Analyzer[Amplitude Analyzer]
    Analyzer --> RMSEnergy[RMS Energy]
    RMSEnergy --> Controller[LipSync Controller]
    Controller --> MorphTargets[Morph Targets]
    MorphTargets --> Metal[Metal Render System]
    Metal --> Screen(Display)

    style Silero fill:#7c3aed,stroke:#fff,color:#fff
    style ServerVAD fill:#10a37f,stroke:#fff,color:#fff
    style API fill:#10a37f,stroke:#fff,color:#fff
    style Metal fill:#00e676,stroke:#fff,color:#000
    style RTC fill:#2979ff,stroke:#fff,color:#fff
    style VoiceEvent fill:#0f172a,stroke:#334155,color:#94a3b8,font-size:11px
    style Commit fill:#0f172a,stroke:#334155,color:#94a3b8,font-size:11px
    style WebRTCLink fill:#0f172a,stroke:#334155,color:#94a3b8,font-size:11px
    style RMSEnergy fill:#0f172a,stroke:#334155,color:#94a3b8,font-size:11px
    style MorphTargets fill:#0f172a,stroke:#334155,color:#94a3b8,font-size:11px
```

### AI Voice & Persona System

Each character model carries her own system prompt and OpenAI voice model, applied automatically on selection.

```mermaid
graph TD
    Select[Character Selection]

    Select --> Ekaterina[Ekaterina]
    Select --> Sonya[Sonya]

    Ekaterina --> EV[Voice: shimmer]
    Ekaterina --> EP[Persona: Onee-san\nGentle · Caring · Japanese]

    Sonya --> SV[Voice: marin]
    Sonya --> SP[Persona: Dedicatus\nTsundere Queen · Sharp · Flustered]

    EV --> Session[session.update]
    EP --> Session
    SV --> Session
    SP --> Session

    Session --> OpenAI[OpenAI Realtime API]

    style Ekaterina fill:#f472b6,stroke:#fff,color:#fff
    style Sonya fill:#7c3aed,stroke:#fff,color:#fff
    style OpenAI fill:#10a37f,stroke:#fff,color:#fff
    style Session fill:#1e293b,stroke:#fff,color:#fff
```

### Model Loading & Rendering

```mermaid
sequenceDiagram
    participant App as SwiftUI View
    participant Loader as VRM Loader
    participant GPU as Metal Compute
    participant Render as MToon Shader

    App->>Loader: Request .vrm / .glb
    Loader->>Loader: Parse GLTF + VRM Extensions
    Loader->>GPU: Upload Vertex & Spring-Bone Buffers
    loop Every Frame
        GPU->>GPU: Calculate Physics (Spring-Bones)
        GPU->>Render: Update Vertex Positions
        Render->>App: Present Rendered Frame
    end
```

---

## ⚙️ Requirements

| Component | Minimum Version |
| :--- | :--- |
| **Operating System** | iOS 17.0+ |
| **Development** | Xcode 16.0+ |
| **Language** | Swift 6.0 |
| **Hardware** | A12 Bionic or newer (for GPU Physics) |

---

## ⬇️ Installation

```bash
# Clone the repository
git clone https://github.com/kevinliddel/NeuraLink.git

# Open in Xcode
open NeuraLink/NeuraLink.xcodeproj
```

---

## 🧩 Proof of Concept

Here is a video of the proof of concept:

[Proof-of-Concept](https://github.com/user-attachments/assets/2dc35314-fa8e-4b78-8507-b88d96d8c420)

---

## ⚖️ License

NeuraLink is released under the **MIT License** — you are free to use, modify, and distribute this software for any purpose. See [LICENSE](./LICENSE) for the full text.