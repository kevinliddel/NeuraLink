#include "vrm_physics_core.hpp"
#include <cmath>
#include <algorithm>

namespace VRM {
namespace Physics {

Solver::Solver() {}
Solver::~Solver() {}

void Solver::update(float deltaTime) {
    // Fixed timestep accumulation logic should be handled by the caller (Swift)
    // but we'll provide the basic step logic here.
    step(deltaTime);
}

void Solver::step(float dt) {
    m_windTime += dt;
    
    for (auto& chain : m_chains) {
        for (size_t i = 0; i < chain.jointIndices.size() - 1; ++i) {
            uint32_t headIdx = chain.jointIndices[i];
            uint32_t tailIdx = chain.jointIndices[i+1];
            
            auto& head = m_bones[headIdx];
            auto& headParams = m_boneParams[headIdx];
            
            // 1. Inertia Calculation (Verlet)
            simd_float3 inertia = (head.currentTail - head.prevTail) * (1.0f - headParams.dragForce);
            
            // Stiffness: Return to original orientation
            // Simplified for the core: we assume parent orientation is identity or handled by the bridge
            // In a full implementation, we'd multiply by parent world rotation
            simd_float3 stiffness = dt * simd_act(head.initialLocalRotation, head.boneAxis) * headParams.stiffness;
            
            // Gravity & External Forces
            simd_float3 external = dt * headParams.gravityDir * headParams.gravityPower;
            
            // Wind (Kawaii Extension)
            float windPhase = m_windTime * 2.0f; // Frequency
            simd_float3 wind = m_windDir * m_windStrength * (0.5f + 0.5f * sinf(windPhase));
            external += dt * wind;
            
            simd_float3 nextTail = head.currentTail + inertia + stiffness + external;
            
            // 2. Length Constraint
            simd_float3 headPos = {0, 0, 0}; // Root of this joint is world (0,0,0) in its own frame
            // Note: Real world positions are added by the bridge or maintained in world space.
            // For this core, we assume 'head.currentTail' is relative to headPos.
            float len = simd_length(nextTail - headPos);
            if (len > 0.0001f) {
                nextTail = headPos + simd_normalize(nextTail - headPos) * head.boneLength;
            }
            
            // 3. Collision
            resolveCollision(nextTail, headParams.hitRadius, chain.colliderGroupIndices);
            
            // 4. Angular Limit (Kawaii Extension)
            if (m_limitAngles[headIdx] > 0.0f) {
                float limitRad = m_limitAngles[headIdx] * (M_PI / 180.0f);
                simd_float3 dir = simd_normalize(nextTail - headPos);
                float angle = acosf(simd_dot(head.boneAxis, dir));
                if (angle > limitRad) {
                    simd_float3 axis = simd_normalize(simd_cross(head.boneAxis, dir));
                    simd_quatf correction = simd_quaternion(limitRad, axis);
                    nextTail = headPos + simd_act(correction, head.boneAxis) * head.boneLength;
                }
            }
            
            // Update state
            head.prevTail = head.currentTail;
            head.currentTail = nextTail;
        }
    }
}

void Solver::resolveCollision(simd_float3& position, float hitRadius, const std::vector<uint32_t>& groups) {
    for (uint32_t groupIdx : groups) {
        if (groupIdx >= m_colliderGroups.size()) continue;
        
        for (uint32_t colIdx : m_colliderGroups[groupIdx]) {
            if (colIdx >= m_colliders.size()) continue;
            
            const auto& col = m_colliders[colIdx];
            simd_float3 colPos = simd_make_float3(col.worldMatrix.columns[3]);
            simd_float3 delta = position - colPos;
            float dist = 0.0f;
            simd_float3 normal = {0, 0, 0};
            
            switch (col.type) {
                case ColliderType::Sphere: {
                    dist = simd_length(delta);
                    normal = (dist > 0.0001f) ? delta / dist : simd_make_float3(0, 1, 0);
                    float combinedRadius = col.radius + hitRadius;
                    if (dist < combinedRadius) {
                        position = colPos + normal * combinedRadius;
                    }
                    break;
                }
                case ColliderType::Box: {
                    // Simplified AABB for the core
                    simd_float3 localPos = position - colPos;
                    simd_float3 clamped = simd_clamp(localPos, -col.size, col.size);
                    float d = simd_distance(localPos, clamped);
                    if (d < hitRadius) {
                        // Push out logic
                        // ... simplified for now
                    }
                    break;
                }
                default: break;
            }
        }
    }
}

void Solver::addBone(const BoneState& bone, const JointParams& params) {
    m_bones.push_back(bone);
    m_boneParams.push_back(params);
    m_limitAngles.push_back(0.0f);
}

void Solver::addChain(const SpringChain& chain) {
    m_chains.push_back(chain);
}

void Solver::addCollider(const Collider& collider) {
    m_colliders.push_back(collider);
}

void Solver::addChainFromVRM0Root(uint32_t rootNodeIndex, 
                                  const std::vector<uint32_t>& colliderGroups,
                                  GetChildrenFunc getChildren, 
                                  void* context) {
    // Recursive traversal to find all paths (chains) from this root
    std::vector<uint32_t> currentPath;
    
    auto traverse = [&](auto self, uint32_t nodeIdx) -> void {
        currentPath.push_back(nodeIdx);
        
        std::vector<uint32_t> children = getChildren(nodeIdx, context);
        if (children.empty()) {
            // Leaf node reached, add this path as a chain
            SpringChain chain;
            chain.name = "VRM0_Chain_" + std::to_string(rootNodeIndex);
            chain.jointIndices = currentPath;
            chain.colliderGroupIndices = colliderGroups;
            addChain(chain);
        } else {
            for (uint32_t childIdx : children) {
                self(self, childIdx);
            }
        }
        
        currentPath.pop_back();
    };
    
    traverse(traverse, rootNodeIndex);
}

void Solver::setLimitAngle(uint32_t boneIndex, float angleDegrees) {
    if (boneIndex < m_limitAngles.size()) {
        m_limitAngles[boneIndex] = angleDegrees;
    }
}

} // namespace Physics
} // namespace VRM
