//
//  vrm_motion_core.cpp
//  NeuraLink
//
//  Created by Dedicatus on 12/05/2026.
//

#include "vrm_motion_core.hpp"
#include <cmath>

namespace NeuraLink {

MotionMatchingEngine::MotionMatchingEngine() {
    // Phase 2: Initialize mock database
    // In a production environment, this would be loaded from a binary file
    m_currentPose.rootTranslation = {0, 0, 0};
}

MotionMatchingEngine::~MotionMatchingEngine() {}

void MotionMatchingEngine::update(float dt) {
    m_time += dt;

    // 1. Compute current feature vector
    MotionFeature query = computeCurrentFeature();

    // 2. Find best match in database
    int bestIdx = findBestMatch(query);

    if (bestIdx >= 0 && bestIdx < static_cast<int>(m_database.poses.size())) {
        // Phase 2: Data-driven motion (NMM)
        // We directly use the pose from the manifold
        m_currentPose = m_database.poses[bestIdx];
    } else {
        // Fallback: Natural Neutral Stance (Relaxed Arms/Legs)
        float breathFreq = 1.2f;
        float breathCycle = std::sin(m_time * breathFreq);
        float spineBreathing = breathCycle * 0.015f * m_activity;

        float hipsX = std::sin(m_time * 0.5f) * 0.02f * m_activity;
        float hipsZ = std::cos(m_time * 0.4f) * 0.01f * m_activity;
        
        m_currentPose.bones["hips"] = { {std::sin(hipsX/2), 0, std::sin(hipsZ/2), std::cos(hipsX/2)}, {0, 0, 0} };
        m_currentPose.bones["spine"] = { {std::sin(spineBreathing/2), 0, 0, std::cos(spineBreathing/2)}, {0, 0, 0} };
        
        float headYaw = std::sin(m_time * 0.2f) * 0.05f * m_activity;
        m_currentPose.bones["head"] = { {0, std::sin(headYaw/2), 0, std::cos(headYaw/2)}, {0, 0, 0} };
        
        // Relaxed arms (A-pose instead of T-pose)
        float armDrop = 0.6f; 
        m_currentPose.bones["leftUpperArm"] = { {0, 0, std::sin(armDrop/2), std::cos(armDrop/2)}, {0, 0, 0} };
        m_currentPose.bones["rightUpperArm"] = { {0, 0, -std::sin(armDrop/2), std::cos(armDrop/2)}, {0, 0, 0} };
        
        // Slight knee bend for weight
        float kneeBend = 0.1f;
        m_currentPose.bones["leftLowerLeg"] = { {std::sin(kneeBend/2), 0, 0, std::cos(kneeBend/2)}, {0, 0, 0} };
        m_currentPose.bones["rightLowerLeg"] = { {std::sin(kneeBend/2), 0, 0, std::cos(kneeBend/2)}, {0, 0, 0} };
    }
}

void MotionMatchingEngine::setTarget(const std::string& emotion, float activity) {
    m_emotion = emotion;
    m_activity = activity;
}

HumanoidPose MotionMatchingEngine::getCurrentPose() const {
    return m_currentPose;
}

int MotionMatchingEngine::findBestMatch(const MotionFeature& currentQuery) {
    if (m_database.features.empty()) return -1;
    
    // NMM Search: Find feature with minimal (MatchingCost + ContinuityCost)
    int bestIdx = 0;
    float minScore = 1e9f;
    
    // Continuity logic: stay close to the current sequence to avoid jitter
    static int lastBestIdx = 0;
    
    for (size_t i = 0; i < m_database.features.size(); ++i) {
        float matchingScore = 0;
        for (size_t j = 0; j < currentQuery.data.size(); ++j) {
            float diff = currentQuery.data[j] - m_database.features[i].data[j];
            matchingScore += diff * diff;
        }
        
        // Continuity Cost: Penalize frames that are not the next frame in the sequence
        float continuityScore = 0;
        int dist = std::abs(static_cast<int>(i) - (lastBestIdx + 1));
        if (dist > 1) {
            continuityScore = 0.5f; // Penalty for jumping
        }
        
        float totalScore = matchingScore + continuityScore;
        
        if (totalScore < minScore) {
            minScore = totalScore;
            bestIdx = static_cast<int>(i);
        }
    }
    
    lastBestIdx = bestIdx;
    return bestIdx;
}

void MotionMatchingEngine::addPoseToDatabase(const HumanoidPose& pose) {
    m_database.poses.push_back(pose);
    
    // Phase 2 Feature: Map the pose to its emotional context
    // In a full implementation, we'd extract these from the clip metadata.
    // For now, we'll tag them based on the current engine state during loading.
    MotionFeature feature;
    feature.data.push_back(m_activity);
    feature.data.push_back(static_cast<float>(m_emotion.length()));
    
    m_database.features.push_back(feature);
}

void MotionMatchingEngine::clearDatabase() {
    m_database.poses.clear();
    m_database.features.clear();
}

MotionFeature MotionMatchingEngine::computeCurrentFeature() const {
    MotionFeature feature;
    // Query features: current target activity and emotional length
    feature.data.push_back(m_activity);
    feature.data.push_back(static_cast<float>(m_emotion.length()));
    return feature;
}

} // namespace NeuraLink
