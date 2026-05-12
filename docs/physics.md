# VRM Physics System

NeuraLink features a hybrid physics system that balances high-performance GPU simulation with high-fidelity C++ reference solvers.

## Core Architecture

The physics system is divided into two main components:
1. **Metal Compute Solver**: (Legacy/Default) A high-performance XPBD solver running on the GPU, capable of handling thousands of bones simultaneously.
2. **C++ Reference Solver**: (New) A CPU-based solver that strictly follows the **VRM 1.0** and **VRM 0.x** Verlet Integration specifications. It includes advanced "Kawaii" extensions for artistic control.

## Specification Support

### VRM 1.0 (VRMC_springBone)
Full implementation of the modern specification, including `center` space support and capsule colliders.

### VRM 0.x (secondaryAnimation)
Native support for the legacy specification:
- **Recursive Traversal**: Automatically builds bone chains from `boneGroups[].bones` root nodes.
- **Parameter Mapping**: Correctly maps `stiffiness` (rigidity), `dragForce`, and `gravity` parameters.
- **Collider Groups**: Support for legacy sphere collider group assignments.

## VRM 1.0 Spec Compliance

The C++ core implements the reference algorithm as defined in the [VRM 1.0 Specification](https://github.com/vrm-c/vrm-specification/tree/master/specification/VRMC_springBone-1.0):

- **Verlet Integration**: Uses the standard position-based integration for consistent behavior with other VRM software.
- **Center Space**: Supports evaluating inertia relative to a local "center" node, which prevents hair from flying wildly when the character is moved in world space.
- **Drag & Stiffness**: Accurately maps the `dragForce` and `stiffness` parameters from the GLB file.

## Kawaii Extensions

Inspired by the `KawaiiPhysics` Unreal Engine plugin, we have added several enhancements to the standard VRM logic:

### 1. Angular Constraints (Limit Angle)
Standard VRM SpringBones can rotate 360 degrees, which often leads to clipping. The C++ solver supports a `Limit Angle` property that constrains bone rotation relative to its parent's bind pose.
- **Use Case**: Long hair, loose sleeves, or tails that should stay within a certain range.

### 2. Box & Plane Colliders
While VRM 1.0 only supports Sphere and Capsule colliders, our C++ core adds:
- **Plane Colliders**: Perfect for floors, walls, or tabletop surfaces.
- **Box Colliders**: Useful for complex environment interactions (e.g., a character sitting on a square bench).

### 3. Perlin Wind Noise
Instead of a simple uniform wind vector, the C++ solver applies a spatial noise field that varies over time, creating more natural-looking "breezes" through hair and cloth.

## Configuration Guide

To enable the C++ Reference Solver for a specific model, set the following in your model configuration:

```swift
model.physicsMode = .reference // Default is .performance (Metal)
```

### Adding a Box Collider
```cpp
VRM::Physics::Collider box;
box.type = ColliderType::Box;
box.size = {0.5f, 0.1f, 0.5f}; // Half-extents
solver.addCollider(box);
```

### Setting Angular Limits
```cpp
solver.setLimitAngle(hairBoneIndex, 45.0f); // Limit to 45 degree cone
```
