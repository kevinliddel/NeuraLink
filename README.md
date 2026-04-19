# 🌌 NeuraLink

<p align="center">
  <img src="https://img.shields.io/badge/iOS-17.0%2B-blue?style=flat&logo=apple" alt="iOS" />
  <img src="https://img.shields.io/badge/Swift-6.0-orange?style=flat&logo=swift" alt="Swift" />
  <img src="https://img.shields.io/badge/Graphics-Metal-brightgreen?style=flat&logo=metal" alt="Metal" />
</p>

A high-performance, native iOS VRM character viewer and AI companion built from the ground up using **Metal** and **SwiftUI**. NeuraLink integrates state-of-the-art WebRTC audio streaming for real-time AI interaction with synchronized visual feedback.

---

## ✨ Features

- **Native Metal Engine**: Custom MToon shaders and GPU-accelerated rendering.
- **Spring-Bone Physics**: Real-time GPU compute for hair and clothing movement.
- **Neural Lip-Sync**: Real-time audio amplitude analysis mapped to VRM blend shapes.
- **Advanced Camera**: Orbit controls with look-at behavior following the viewing angle.
- **Universal Support**: Handles both VRM 0.x and 1.0 specifications.
- **Arknight inspired turn back at the camera**: When you rotate the camera to look behind the character, the character will turn her head to look at you after 5 seconds.


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

NeuraLink uses a high-efficiency pipeline to ensure zero-latency synchronization between the AI's voice and the character's mouth movements.

```mermaid
graph TD
    API[OpenAI Realtime API] -- WebRTC --> RTC(RTCAudioSession)
    RTC --> Buffer[PCM Audio Buffer]
    Buffer --> Output[Device Speakers]
    Buffer --> Analyzer[Amplitude Analyzer]
    Analyzer -- RMS Energy --> Controller[LipSync Controller]
    Controller -- Morph Targets --> Metal[Metal Render System]
    Metal --> Screen(iOS Display)
    
    style API fill:#10a37f,stroke:#fff,color:#fff
    style Metal fill:#00e676,stroke:#fff,color:#000
    style RTC fill:#2979ff,stroke:#fff,color:#fff
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

