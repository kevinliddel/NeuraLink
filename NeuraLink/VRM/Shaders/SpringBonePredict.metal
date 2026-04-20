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

    // Root bones are kinematically driven by the animation; skip simulation.
    uint parentIndex = boneParams[id].parentIndex;
    if (parentIndex == 0xFFFFFFFF) return;

    // --- NaN / Inf recovery ---------------------------------------------------
    float3 currPos = bonePosCurr[id];
    float3 prevPos = bonePosPrev[id];
    float restLength = restLengths[id];

    if (isnan(currPos.x) || isnan(currPos.y) || isnan(currPos.z) ||
        isinf(currPos.x) || isinf(currPos.y) || isinf(currPos.z)) {
        float3 parentPos = bonePosCurr[parentIndex];
        float safeLen = max(restLength, 0.01);
        float3 resetPos = parentPos + float3(0.0, -safeLen, 0.0);
        bonePosCurr[id] = resetPos;
        bonePosPrev[id] = resetPos;
        return;
    }
    if (isnan(prevPos.x) || isnan(prevPos.y) || isnan(prevPos.z) ||
        isinf(prevPos.x) || isinf(prevPos.y) || isinf(prevPos.z)) {
        bonePosPrev[id] = currPos;
        prevPos = currPos;
    }

    // --- Verlet velocity ------------------------------------------------------
    float3 velocity = currPos - prevPos;

    // Clamp to 1 m/step (= 120 m/s at 120 Hz) — prevents explosion on teleport.
    float velMag = length(velocity);
    if (velMag > 1.0) velocity = (velocity / velMag) * 1.0;
    if (isnan(velocity.x) || isnan(velocity.y) || isnan(velocity.z)) velocity = float3(0.0);

    // --- Inertia compensation -------------------------------------------------
    // When the parent (head) moves upward, the distance constraint correction from
    // the previous frame becomes upward velocity here, causing a snap/jerk.
    // Subtracting the parent's upward delta cancels that synthetic velocity so hair
    // trails naturally. Lateral compensation is skipped to avoid pushing bangs
    // into the face on head tilts. Disabled during settling so gravity can settle
    // bones to their natural hanging position.
    if (globalParams.settlingFrames == 0) {
        float3 parentDelta = bonePosCurr[parentIndex] - bonePosPrev[parentIndex];
        float3 upwardDelta = float3(0.0, max(0.0, parentDelta.y), 0.0);
        float upSpeed = length(upwardDelta);
        float compensationFactor = smoothstep(0.001, 0.015, upSpeed);
        velocity -= upwardDelta * compensationFactor;
    }

    // Snapshot current position as previous before we mutate it.
    bonePosPrev[id] = bonePosCurr[id];

    // --- Wind -----------------------------------------------------------------
    float time = globalParams.windPhase;
    float gust = 0.7 + 0.3 * (0.5 + 0.5 * sin(globalParams.windFrequency * time * 0.5)
                                   + 0.15 * sin(globalParams.windFrequency * time * 1.3));
    float windInfluence = smoothstep(0.15, 0.35, boneParams[id].drag);
    float3 windForce = globalParams.windAmplitude * globalParams.windDirection
                     * gust * windInfluence;

    // --- PBD stiffness target -------------------------------------------------
    // Position-mixing (not force): guarantees dt-independent, consistent correction.
    // blend = 1 − exp(−s · dtSub · 2.4) — exponential approach to rest pose, properly
    // frame-rate-independent. At 120 Hz and s=1.0 this is ≈ 2 % per substep (matches
    // the original K=0.02 constant), but higher-stiffness bones (s=3–5) now spring back
    // proportionally faster instead of being linearly under-damped.
    float3 parentPos = bonePosCurr[parentIndex];
    float3 bindDir   = bindDirections[parentIndex];
    float  bindLen   = length(bindDir);

    float3 stiffnessTarget = bonePosCurr[id];
    float  stiffnessBlend  = 0.0;

    bool stiffnessValid = !isnan(parentPos.x) && !isnan(parentPos.y) && !isnan(parentPos.z)
                       && bindLen > 0.001 && restLength > 0.0;
    if (stiffnessValid) {
        stiffnessTarget = parentPos + (bindDir / bindLen) * restLength;
        float s = boneParams[id].stiffness;
        if (s > 0.001) {
            stiffnessBlend = clamp(1.0 - exp(-s * globalParams.dtSub * 2.4), 0.0, 0.95);
        }
    }

    // --- Drag + gravity -------------------------------------------------------
    // DT-scaled drag: velocity *= (1 - drag * dt * 60).
    // drag=1.0 → ~50 % velocity loss per 1/60 s frame (frame-rate independent).
    float effectiveDrag = clamp(boneParams[id].drag * globalParams.dragMultiplier, 0.0, 0.99);
    float dragFactor    = clamp(1.0 - effectiveDrag * globalParams.dtSub * 60.0, 0.01, 1.0);

    float3 effectiveGravity = boneParams[id].gravityDir
                            * length(globalParams.gravity)
                            * boneParams[id].gravityPower;

    // Inertial trail: character root movement pushes hair in the opposite direction.
    float3 inertialForce = -globalParams.externalVelocity * 0.5;

    // --- Verlet step ----------------------------------------------------------
    float3 newPos = bonePosCurr[id]
                  + velocity * dragFactor
                  + (effectiveGravity + windForce + inertialForce)
                    * globalParams.dtSub * globalParams.dtSub;

    // Apply stiffness blend AFTER Verlet, BEFORE distance constraint.
    if (stiffnessBlend > 0.001) newPos = mix(newPos, stiffnessTarget, stiffnessBlend);

    // Guard against large single-step displacement.
    float3 disp = newPos - bonePosCurr[id];
    float dispLen = length(disp);
    if (dispLen > 2.0) newPos = bonePosCurr[id] + (disp / dispLen) * 2.0;

    // Sanity: reset if bone drifted > 10 m from parent.
    if (length(newPos - bonePosCurr[parentIndex]) > 10.0) {
        newPos = bonePosCurr[parentIndex] + float3(0.0, -max(restLength, 0.01), 0.0);
    }

    // Final NaN / Inf guard.
    if (isnan(newPos.x) || isnan(newPos.y) || isnan(newPos.z) ||
        isinf(newPos.x) || isinf(newPos.y) || isinf(newPos.z)) {
        float3 p = bonePosCurr[parentIndex];
        newPos = (isnan(p.x) || isnan(p.y) || isnan(p.z))
               ? bonePosPrev[id]
               : (p + float3(0.0, -max(restLength, 0.01), 0.0));
        bonePosPrev[id] = newPos;
    }

    bonePosCurr[id] = newPos;
}
