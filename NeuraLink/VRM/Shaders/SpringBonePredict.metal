#include <metal_stdlib>
using namespace metal;

struct SpringBoneParams {
    float3 gravity;       // offset 0, size 12, padded to 16
    float dtSub;          // offset 16
    float windAmplitude;  // offset 20
    float windFrequency;  // offset 24
    float windPhase;      // offset 28
    float3 windDirection; // offset 32, size 12, padded to 16
    uint substeps;        // offset 48
    uint numBones;        // offset 52
    uint numSpheres;      // offset 56
    uint numCapsules;     // offset 60
    uint numPlanes;       // offset 64
    uint settlingFrames;  // offset 68
    float dragMultiplier; // offset 72 - global drag multiplier (1.0 = normal, >1.0 = braking)
    uint _padding1;       // offset 76 - padding for float3 alignment
    float3 externalVelocity; // offset 80 - character root velocity for inertia (requires 16-byte alignment)
};

struct BoneParams {
    float stiffness;
    float drag;
    float radius;
    uint parentIndex;
    float gravityPower;       // Multiplier for global gravity (0.0 = no gravity, 1.0 = full)
    uint colliderGroupMask;   // Bitmask of collision groups this bone collides with
    float3 gravityDir;        // Direction vector (normalized, typically [0, -1, 0])
};

kernel void springBonePredict(
    device float3* bonePosPrev [[buffer(0)]],
    device float3* bonePosCurr [[buffer(1)]],
    constant BoneParams* boneParams [[buffer(2)]],
    constant SpringBoneParams& globalParams [[buffer(3)]],
    constant float* restLengths [[buffer(4)]],
    constant float3* bindDirections [[buffer(11)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= globalParams.numBones) return;

    // Skip prediction for root bones - they are kinematically driven
    uint parentIndex = boneParams[id].parentIndex;
    if (parentIndex == 0xFFFFFFFF) {
        // Root bones maintain their animated position
        // Their position was already set by the kinematic kernel
        return;
    }

    // EARLY NaN DETECTION: If current position is already corrupted, reset immediately
    float3 currPos = bonePosCurr[id];
    float3 prevPos = bonePosPrev[id];
    float restLength = restLengths[id];

    if (isnan(currPos.x) || isnan(currPos.y) || isnan(currPos.z) ||
        isinf(currPos.x) || isinf(currPos.y) || isinf(currPos.z)) {
        // Current position is corrupted - reset to hanging position below parent
        float3 parentPos = bonePosCurr[parentIndex];
        float safeRestLen = max(restLength, 0.01);
        float3 resetPos = parentPos + float3(0.0, -safeRestLen, 0.0);
        bonePosCurr[id] = resetPos;
        bonePosPrev[id] = resetPos;
        return;
    }

    if (isnan(prevPos.x) || isnan(prevPos.y) || isnan(prevPos.z) ||
        isinf(prevPos.x) || isinf(prevPos.y) || isinf(prevPos.z)) {
        // Previous position is corrupted - set to current to zero velocity
        bonePosPrev[id] = currPos;
        prevPos = currPos;
    }

    // CRITICAL: Calculate velocity BEFORE saving previous position
    // This is the core of Verlet integration - velocity is implicit in position difference
    float3 velocity = bonePosCurr[id] - bonePosPrev[id];

    // VELOCITY CLAMPING: Prevent velocity from growing unbounded
    // Max velocity of 1.0 m/frame at 120Hz = 120 m/s, more than enough for any realistic motion
    const float MAX_VELOCITY = 1.0;
    float velocityMag = length(velocity);
    if (velocityMag > MAX_VELOCITY) {
        velocity = (velocity / velocityMag) * MAX_VELOCITY;
    }

    // NaN check on velocity - reset to zero if invalid
    if (isnan(velocity.x) || isnan(velocity.y) || isnan(velocity.z)) {
        velocity = float3(0.0);
    }

    // INERTIA COMPENSATION: When parent moves UP, child should maintain its WORLD position
    // momentarily due to inertia. Without compensation, constraint corrections from the
    // previous frame become velocity this frame - when parent moves up, constraint pulls
    // child up, and that becomes upward velocity.
    //
    // SETTLING PERIOD: Skip compensation during initial frames to let bones settle naturally
    // with gravity. Otherwise compensation fights the settling and bones stay in bind pose.
    //
    // DIRECTION-AWARE: Only compensate for UPWARD parent movement (fighting gravity).
    // During descent/landing, let hair float naturally - compensating downward movement
    // would create upward force and make hair shoot up on landing.
    //
    // We scale the compensation based on movement magnitude:
    // INERTIA COMPENSATION DISABLED FOR DEBUGGING
    // If flutter stops with this disabled, the compensation logic is the culprit.
    // - Small movements (idle breathing/sway): minimal compensation, hair follows gently
    // - Large movements (jumps): full compensation, hair trails behind with inertia
    /*
    if (globalParams.settlingFrames == 0) {
        float3 parentDelta = bonePosCurr[parentIndex] - bonePosPrev[parentIndex];

        // Only compensate for upward Y movement - no lateral compensation
        // Lateral compensation can push bangs into the face during head tilts
        float3 compensatedDelta = float3(
            0.0,                      // No X compensation
            max(0.0, parentDelta.y),  // Only upward movement
            0.0                       // No Z compensation
        );

        float parentSpeed = length(compensatedDelta);
        float compensationFactor = smoothstep(0.002, 0.02, parentSpeed);
        velocity = velocity - compensatedDelta * compensationFactor;
    }
    */

    // Now save current position as previous for next frame
    bonePosPrev[id] = bonePosCurr[id];

    // Calculate wind force with natural gusts (steady direction, varying intensity)
    float time = globalParams.windPhase;
    // Multi-frequency gusts for organic feel (always positive, never reverses)
    float gust1 = sin(globalParams.windFrequency * time * 0.5);      // Slow base variation
    float gust2 = sin(globalParams.windFrequency * time * 1.3) * 0.3; // Faster overlay
    // Range: 0.4 to 1.0 - noticeable gusts without reversing
    float gustFactor = 0.7 + 0.3 * (0.5 + 0.5 * gust1 + gust2 * 0.5);

    // Wind influence based on drag (air resistance)
    // Hair: high drag (~0.4) catches wind
    // Bust: low drag (~0.05) ignores wind
    // Gradual transition from 0.15-0.35 for smooth blending
    float drag = boneParams[id].drag;
    float windInfluence = smoothstep(0.15, 0.35, drag);
    float3 windForce = globalParams.windAmplitude *
                      globalParams.windDirection *
                      gustFactor *
                      windInfluence;

    // PBD STIFFNESS MODEL: Direct position mixing toward bind pose
    //
    // Why PBD position mixing instead of force-based springs:
    // 1. Force-based springs fight dt² scaling (0.00007 at 120Hz makes forces negligible)
    // 2. Distance constraint solver creates "synthetic velocity" that opposes weak forces
    // 3. Position mixing guarantees consistent % correction per substep regardless of dt
    //
    // Formula: newPos = mix(currentPos, targetPos, stiffness * K)
    // - K is tuned so stiffness=1.0 gives strong snap, stiffness=0.1 gives gentle return
    // - Applied AFTER Verlet integration but BEFORE distance constraint
    //
    float3 parentPos = bonePosCurr[parentIndex];
    // FIX: Use bindDirections[parentIndex], not bindDirections[id]
    // bindDirections[N] = direction from Node N to Node N+1 (current→child)
    // When simulating Node id, we need direction from parent (id-1) toward us
    // That's bindDirections[parentIndex] = direction from parent's node to parent's child (us)
    float3 bindDir = bindDirections[parentIndex];
    float bindDirLen = length(bindDir);

    // Calculate target position for stiffness blend (applied later after Verlet)
    float3 stiffnessTargetPos = bonePosCurr[id]; // Default: no change
    float stiffnessBlendFactor = 0.0;

    bool stiffnessValid = !isnan(parentPos.x) && !isnan(parentPos.y) && !isnan(parentPos.z)
                       && bindDirLen > 0.001 && restLength > 0.0;

    if (stiffnessValid) {
        float3 safeBindDir = bindDir / bindDirLen;
        stiffnessTargetPos = parentPos + safeBindDir * restLength;

        float stiffness = boneParams[id].stiffness;

        // SETTLING: Gradually enable stiffness over the settling period
        float settlingFrames = float(globalParams.settlingFrames);
        float settlingStiffnessScale = 1.0 - smoothstep(0.0, 60.0, settlingFrames);
        stiffness *= settlingStiffnessScale;

        if (stiffness > 0.001) {
            // PBD stiffness: blend factor determines % of error corrected per substep
            // K=0.15 tuned so: stiffness=1.0 → 15% correction, stiffness=0.1 → 1.5% correction
            // This is dt-independent and consistent across frame rates
            stiffnessBlendFactor = stiffness * 0.15;
        }
    }

    // Verlet integration with drag and external forces
    // Apply global drag multiplier for interruption braking (normally 1.0)
    float baseDrag = boneParams[id].drag * globalParams.dragMultiplier;

    // SETTLING BOOST: During settling period, reduce drag and boost gravity
    float settlingFrames = float(globalParams.settlingFrames);
    float settlingFactor = smoothstep(0.0, 30.0, settlingFrames);

    // DT-SCALED DRAG: velocity *= (1 - drag * dt * scale)
    // This makes drag frame-rate independent and properly normalized
    // Scale factor of 60 means drag=1.0 gives ~50% velocity loss per 1/60s frame
    float effectiveDrag = baseDrag * (1.0 - settlingFactor * 0.7);
    effectiveDrag = clamp(effectiveDrag, 0.0, 0.99);
    float dragFactor = 1.0 - effectiveDrag * globalParams.dtSub * 60.0;
    dragFactor = clamp(dragFactor, 0.01, 1.0); // Ensure positive, non-zero
    float gravityBoost = 1.0 + settlingFactor * 4.0;

    // Per-joint gravity
    float gravityMagnitude = length(globalParams.gravity) * gravityBoost;
    float3 effectiveGravity = boneParams[id].gravityDir * gravityMagnitude * boneParams[id].gravityPower;

    // Inertial force from character movement
    // When character moves in a direction, hair/cloth should trail behind (opposite direction)
    // Scale by 0.5 for natural feel - too strong makes hair whip around
    float3 inertialForce = -globalParams.externalVelocity * 0.5;

    // Verlet integration: position += velocity * drag + acceleration * dt²
    float3 newPos = bonePosCurr[id] + velocity * dragFactor +
                    (effectiveGravity + windForce + inertialForce) * globalParams.dtSub * globalParams.dtSub;

    // PBD STIFFNESS: Apply position blend toward bind pose AFTER Verlet, BEFORE constraints
    // This is dt-independent and guarantees consistent % correction per substep
    if (stiffnessBlendFactor > 0.001) {
        newPos = mix(newPos, stiffnessTargetPos, stiffnessBlendFactor);
    }

    // Clamp step size to prevent explosion
    const float MAX_STEP = 2.0;
    float3 displacement = newPos - bonePosCurr[id];
    float stepSize = length(displacement);
    if (stepSize > MAX_STEP) {
        displacement = (displacement / stepSize) * MAX_STEP;
        newPos = bonePosCurr[id] + displacement;
    }

    // POSITION BOUNDS CHECK: Detect if bone has drifted impossibly far
    // If more than 10m from parent, something is wrong - reset to stable position
    float3 toParent = newPos - bonePosCurr[parentIndex];
    float distFromParent = length(toParent);
    if (distFromParent > 10.0) {
        // Reset to rest position below parent
        float safeRestLen = max(restLength, 0.01);
        newPos = bonePosCurr[parentIndex] + float3(0.0, -safeRestLen, 0.0);
    }

    // Final NaN safety check - if result is NaN, reset to stable position
    if (isnan(newPos.x) || isnan(newPos.y) || isnan(newPos.z) ||
        isinf(newPos.x) || isinf(newPos.y) || isinf(newPos.z)) {
        // Reset to rest position hanging below parent
        float3 parentPos = bonePosCurr[parentIndex];
        if (isnan(parentPos.x) || isnan(parentPos.y) || isnan(parentPos.z)) {
            // Parent is also bad - use previous position as last resort
            newPos = bonePosPrev[id];
        } else {
            // Reset to hanging position below parent
            float safeRestLen = max(restLength, 0.01);
            newPos = parentPos + float3(0.0, -safeRestLen, 0.0);
        }
        // Also reset previous position to prevent velocity spike next frame
        bonePosPrev[id] = newPos;
    }

    bonePosCurr[id] = newPos;
}