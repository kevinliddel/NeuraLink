//
//  vrm_motion_dataset.hpp
//  NeuraLink
//
//  Optional generated database loader.
//  The generator can emit `vrm_motion_dataset.generated.cpp` that defines
//  `loadGeneratedDatabase(MotionDatabase&)`.
//

#pragma once

#include "vrm_motion_core.hpp"

namespace NeuraLink {

// Returns true if a compiled-in/generated database is available and loaded.
bool loadGeneratedDatabase(MotionDatabase& db);

} // namespace NeuraLink

