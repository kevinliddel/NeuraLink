//
//  vrm_motion_core.hpp
//  NeuraLink
//
//  Created by Dedicatus on 12/05/2026.
//

#ifndef vrm_motion_core_hpp
#define vrm_motion_core_hpp

#include <vector>
#include <string>
#include <map>

namespace NeuraLink {

/// Simple 3D vector
struct Vector3 {
    float x, y, z;
};

/// Simple Quaternion
struct Quaternion {
    float x, y, z, w;
};

/// Transform for a single bone
struct BoneTransform {
    Quaternion rotation;
    Vector3 translation;
};

/// A full humanoid pose
struct HumanoidPose {
    std::map<std::string, BoneTransform> bones;
    Vector3 rootTranslation;
};

/// Motion features used for matching (positions, velocities, etc.)
struct MotionFeature {
    std::vector<float> data;
};

/// Database of recorded motion fragments
struct MotionDatabase {
    std::vector<HumanoidPose> poses;
    std::vector<MotionFeature> features;
};

/// Motion Matching Engine Core
class MotionMatchingEngine {
public:
    MotionMatchingEngine();
    ~MotionMatchingEngine();

    /// Updates the simulation
    void update(float dt);

    /// Sets the target emotion and activity level
    void setTarget(const std::string& emotion, float activity);

    /// Gets the current computed pose
    HumanoidPose getCurrentPose() const;

    /// Adds a pose to the motion database for matching
    void addPoseToDatabase(const HumanoidPose& pose);

    /// Clears the motion database
    void clearDatabase();

private:
    float m_time = 0.0f;
    float m_activity = 0.5f;
    std::string m_emotion = "neutral";
    
    HumanoidPose m_currentPose;
    MotionDatabase m_database;
    
    /// Finds the best next frame in the database
    int findBestMatch(const MotionFeature& currentQuery);
    
    /// Generates a feature vector for the current state
    MotionFeature computeCurrentFeature() const;
};

} // namespace NeuraLink

#endif /* vrm_motion_core_hpp */
