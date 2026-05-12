#ifndef VRM_PHYSICS_CORE_HPP
#define VRM_PHYSICS_CORE_HPP

#include <simd/simd.h>
#include <vector>
#include <string>

namespace VRM {
namespace Physics {

// MARK: - Constants
struct Constants {
    static constexpr float DefaultHitRadius = 0.05f;
    static constexpr float SubstepRateHz = 120.0f;
    static constexpr float FixedDeltaTime = 1.0f / SubstepRateHz;
};

// MARK: - Data Structures

struct JointParams {
    float hitRadius;
    float stiffness;
    float gravityPower;
    simd_float3 gravityDir;
    float dragForce;
};

struct BoneState {
    simd_float3 currentTail;
    simd_float3 prevTail;
    simd_float3 boneAxis; // Direction to child in rest state
    float boneLength;
    simd_float4x4 initialLocalMatrix;
    simd_quatf initialLocalRotation;
};

enum class ColliderType {
    Sphere,
    Capsule,
    Plane,
    Box
};

struct Collider {
    ColliderType type;
    simd_float3 offset;
    float radius;
    simd_float3 tail; // For capsule
    simd_float3 normal; // For plane
    simd_float3 size;   // For box (half-extents)
    simd_float4x4 worldMatrix;
};

struct SpringChain {
    std::string name;
    std::vector<uint32_t> jointIndices;
    std::vector<uint32_t> colliderGroupIndices;
    int32_t centerNodeIndex = -1; // -1 for world space
};

// MARK: - Core Solver

class Solver {
public:
    Solver();
    ~Solver();

    void update(float deltaTime);
    
    // Setup methods
    void addChain(const SpringChain& chain);
    void addBone(const BoneState& bone, const JointParams& params);
    void addCollider(const Collider& collider);
    
    // VRM 0.x Support: Recursive chain building
    // The caller provides a function to get child indices for a given node.
    typedef std::vector<uint32_t> (*GetChildrenFunc)(uint32_t nodeIndex, void* context);
    void addChainFromVRM0Root(uint32_t rootNodeIndex, 
                              const std::vector<uint32_t>& colliderGroups,
                              GetChildrenFunc getChildren, 
                              void* context);
    
    // Kawaii Extensions
    void setLimitAngle(uint32_t boneIndex, float angleDegrees);
    void setWind(simd_float3 direction, float strength, float frequency);

private:
    void step(float dt);
    void resolveCollision(simd_float3& position, float hitRadius, const std::vector<uint32_t>& groups);
    
    std::vector<SpringChain> m_chains;
    std::vector<BoneState> m_bones;
    std::vector<JointParams> m_boneParams;
    std::vector<Collider> m_colliders;
    std::vector<std::vector<uint32_t>> m_colliderGroups; // Group Index -> List of Collider Indices
    
    // Kawaii Data
    std::vector<float> m_limitAngles; // 0 means no limit
    simd_float3 m_windDir = {1, 0, 0};
    float m_windStrength = 0.0f;
    float m_windTime = 0.0f;
};

} // namespace Physics
} // namespace VRM

#endif // VRM_PHYSICS_CORE_HPP
