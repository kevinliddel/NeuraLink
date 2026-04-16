# NeuraLink

A native iOS VRM model viewer built from scratch using **Metal** and **SwiftUI** — no third-party packages.

## Features

- VRM 0.x and 1.0 model loading
- MToon material rendering via custom Metal shaders
- Spring-bone physics (GPU compute)
- Skeletal animation via `.vrma` clips
- Morph target / blend shape support
- Orbit camera with pan, tilt and pinch-to-zoom
- Idle animation auto-loading from bundle

## Requirements

| | Minimum |
|---|---|
| iOS | 17.0 |
| Xcode | 16.0 |
| Swift | 5.9 |

## Getting Started

1. Clone the repo.
2. Open `NeuraLink.xcodeproj` in Xcode.
3. Drop a `.vrm` file into the project and set its **Target Membership** to **NeuraLink**.
4. Build & run on a device or simulator.

The app will automatically look for `Sonya.vrm` or `Ekaterina.vrm` on launch.  
A `default_state.vrma` or `idle.vrma` in the bundle will be looped as the idle animation.