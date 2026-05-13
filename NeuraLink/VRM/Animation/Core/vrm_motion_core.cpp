//
//  vrm_motion_core.cpp
//  NeuraLink
//
//  Created by Dedicatus on 12/05/2026.
//

#include "vrm_motion_core.hpp"
#include "vrm_motion_dataset.hpp"
#include <cmath>
#include <cstring>
#include <cstdint>
#include <chrono>
#include <algorithm>

namespace NeuraLink {

MotionMatchingEngine::MotionMatchingEngine() {
    // If a generated/compiled-in database exists, load it.
    // Otherwise the Swift side can still populate via vrm_motion_db_* calls.
    loadGeneratedDatabase(m_database);

    // Phase 2: Initialize mock database
    // In a production environment, this would be loaded from a binary file
    m_currentPose.rootTranslation = {0, 0, 0};

    auto seed = static_cast<uint32_t>(
        std::chrono::high_resolution_clock::now().time_since_epoch().count()
    );
    m_rng.seed(seed);
}

MotionMatchingEngine::~MotionMatchingEngine() {}

void MotionMatchingEngine::update(float dt) {
    m_time += dt;

    // Throttle DB advancement to the database sample rate (default 30 FPS).
    // If we update at 60 FPS, we should not advance frames twice as fast.
    m_frameAccumulator += dt;
    if (m_frameAccumulator < (1.0f / m_databaseSampleRate)) {
        return;
    }
    // Consume at most one step per update to keep behavior stable even under long frames.
    m_frameAccumulator = 0.0f;

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
    // Map emotion string to a coarse category id to steer matching.
    std::string e = emotion;
    for (auto& c : e) c = static_cast<char>(::tolower(c));
    if (e.find("talk") != std::string::npos) m_targetCategoryId = 1;         // talking
    else if (e.find("think") != std::string::npos) m_targetCategoryId = 2;   // thinking
    else if (e.find("happy") != std::string::npos) m_targetCategoryId = 3;   // happy
    else if (e.find("sad") != std::string::npos) m_targetCategoryId = 4;     // sad
    else if (e.find("angry") != std::string::npos) m_targetCategoryId = 5;   // angry
    else if (e.find("look") != std::string::npos) m_targetCategoryId = 6;    // looking
    else if (e.find("stretch") != std::string::npos) m_targetCategoryId = 7; // stretching
    else m_targetCategoryId = 0;                                             // idle/misc
}

HumanoidPose MotionMatchingEngine::getCurrentPose() const {
    return m_currentPose;
}

int MotionMatchingEngine::findBestMatch(const MotionFeature& currentQuery) {
    const int dbSize = static_cast<int>(m_database.features.size());
    if (dbSize == 0) return -1;

    // Wrap the expected-next index so we loop back to 0 after the last frame
    int expectedNext = m_lastBestIdx + 1;
    if (expectedNext >= dbSize) {
        expectedNext = 0;
    }
    
    // Keep top-K candidates and randomly pick among them to avoid deterministic looping.
    constexpr int kTopK = 5;
    std::vector<std::pair<float, int>> top;
    top.reserve(kTopK);
    
    for (int i = 0; i < dbSize; ++i) {
        float matchingScore = 0;
        for (size_t j = 0; j < currentQuery.data.size() && j < m_database.features[i].data.size(); ++j) {
            float diff = currentQuery.data[j] - m_database.features[i].data[j];
            matchingScore += diff * diff;
        }
        
        // Continuity: strongly prefer the next sequential frame
        float continuityScore = 0;
        int dist = std::abs(i - expectedNext);
        if (dist == 0) {
            continuityScore = -1.0f; // Strong bonus for natural advancement
        } else if (dist > 1) {
            continuityScore = 0.5f * static_cast<float>(dist); // Scale penalty with distance
        }
        
        float totalScore = matchingScore + continuityScore;

        // Insert into top-K sorted list
        if (static_cast<int>(top.size()) < kTopK) {
            top.emplace_back(totalScore, i);
            std::sort(top.begin(), top.end(), [](auto& a, auto& b) { return a.first < b.first; });
        } else if (totalScore < top.back().first) {
            top.back() = {totalScore, i};
            std::sort(top.begin(), top.end(), [](auto& a, auto& b) { return a.first < b.first; });
        }
    }

    int bestIdx = top.empty() ? 0 : top.front().second;
    if (top.size() > 1) {
        // Softmax sampling over top-K (lower score -> higher probability)
        float minScore = top.front().first;
        std::vector<float> weights;
        weights.reserve(top.size());
        float sum = 0.0f;
        for (auto& [score, _] : top) {
            float w = std::exp(-(score - minScore) * 2.5f);
            weights.push_back(w);
            sum += w;
        }
        std::uniform_real_distribution<float> dist(0.0f, sum);
        float r = dist(m_rng);
        float acc = 0.0f;
        for (size_t k = 0; k < top.size(); ++k) {
            acc += weights[k];
            if (r <= acc) {
                bestIdx = top[k].second;
                break;
            }
        }
    }

    m_lastBestIdx = bestIdx;
    
    // Log every ~1 second (30Hz update rate)
    static int logCounter = 0;
    if (++logCounter >= 30) {
        logCounter = 0;
        printf("[NMM] frame=%d/%d emotion=%s activity=%.2f\n",
               bestIdx, dbSize - 1, m_emotion.c_str(), m_activity);
    }
    
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
    m_lastBestIdx = -1; // Reset sequence position
}

static bool readU32(const uint8_t*& p, const uint8_t* end, uint32_t& out) {
    if (p + 4 > end) return false;
    out = static_cast<uint32_t>(p[0]) |
          (static_cast<uint32_t>(p[1]) << 8) |
          (static_cast<uint32_t>(p[2]) << 16) |
          (static_cast<uint32_t>(p[3]) << 24);
    p += 4;
    return true;
}

static bool readU16(const uint8_t*& p, const uint8_t* end, uint16_t& out) {
    if (p + 2 > end) return false;
    out = static_cast<uint16_t>(p[0]) | (static_cast<uint16_t>(p[1]) << 8);
    p += 2;
    return true;
}

static bool readF32(const uint8_t*& p, const uint8_t* end, float& out) {
    if (p + 4 > end) return false;
    uint32_t bits = static_cast<uint32_t>(p[0]) |
                    (static_cast<uint32_t>(p[1]) << 8) |
                    (static_cast<uint32_t>(p[2]) << 16) |
                    (static_cast<uint32_t>(p[3]) << 24);
    std::memcpy(&out, &bits, sizeof(float));
    p += 4;
    return true;
}

bool MotionMatchingEngine::loadDatabaseFromBinary(const uint8_t* data, size_t size) {
    if (!data || size < 8 + 4 + 4 + 4 + 4) return false;
    const uint8_t* p = data;
    const uint8_t* end = data + size;

    const char expectedMagic[8] = {'N','M','M','D','B','I','N','\0'};
    if (std::memcmp(p, expectedMagic, 8) != 0) {
        return false;
    }
    p += 8;

    uint32_t version = 0;
    uint32_t boneCount = 0;
    uint32_t frameCount = 0;
    if (!readU32(p, end, version)) return false;
    if (version != 1 && version != 2) return false;
    if (!readU32(p, end, boneCount)) return false;
    if (!readU32(p, end, frameCount)) return false;

    std::vector<std::string> bones;
    bones.reserve(boneCount);
    for (uint32_t i = 0; i < boneCount; ++i) {
        uint16_t nameLen = 0;
        if (!readU16(p, end, nameLen)) return false;
        if (p + nameLen > end) return false;
        bones.emplace_back(reinterpret_cast<const char*>(p), reinterpret_cast<const char*>(p + nameLen));
        p += nameLen;
    }

    // Optional category table (v2)
    std::vector<std::string> categories;
    if (version == 2) {
        uint32_t categoryCount = 0;
        if (!readU32(p, end, categoryCount)) return false;
        categories.reserve(categoryCount);
        for (uint32_t i = 0; i < categoryCount; ++i) {
            uint16_t nameLen = 0;
            if (!readU16(p, end, nameLen)) return false;
            if (p + nameLen > end) return false;
            categories.emplace_back(reinterpret_cast<const char*>(p), reinterpret_cast<const char*>(p + nameLen));
            p += nameLen;
        }
    }

    // Pre-size database
    m_database.poses.clear();
    m_database.features.clear();
    m_database.poses.reserve(frameCount);
    m_database.features.reserve(frameCount);

    for (uint32_t fi = 0; fi < frameCount; ++fi) {
        HumanoidPose pose;
        pose.rootTranslation = {0, 0, 0};

        uint16_t categoryIndex = 0;
        if (version == 2) {
            if (!readU16(p, end, categoryIndex)) return false;
        }
        for (uint32_t bi = 0; bi < boneCount; ++bi) {
            float x, y, z, w;
            if (!readF32(p, end, x) || !readF32(p, end, y) || !readF32(p, end, z) || !readF32(p, end, w)) {
                return false;
            }
            BoneTransform t;
            t.rotation = {x, y, z, w};
            t.translation = {0, 0, 0};
            pose.bones[bones[bi]] = t;
        }
        m_database.poses.push_back(pose);

        // Features:
        //  [0] activity (unused by current matchingScore but kept)
        //  [1] category id (coarse tag derived from filename)
        MotionFeature f;
        float cat = 0.0f;
        if (version == 2 && categoryIndex < categories.size()) {
            // Map category strings to stable ids matching setTarget() above.
            const std::string& c = categories[categoryIndex];
            if (c == "talking") cat = 1;
            else if (c == "thinking") cat = 2;
            else if (c == "happy") cat = 3;
            else if (c == "sad") cat = 4;
            else if (c == "angry") cat = 5;
            else if (c == "looking") cat = 6;
            else if (c == "stretching") cat = 7;
            else cat = 0;
        }
        f.data = {m_activity, cat};
        m_database.features.push_back(f);
    }

    m_lastBestIdx = -1;
    return true;
}

MotionFeature MotionMatchingEngine::computeCurrentFeature() const {
    MotionFeature feature;
    // Query features: activity and coarse category id
    feature.data.push_back(m_activity);
    feature.data.push_back(static_cast<float>(m_targetCategoryId));
    return feature;
}

} // namespace NeuraLink
