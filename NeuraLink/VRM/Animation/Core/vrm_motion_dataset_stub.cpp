//
//  vrm_motion_dataset_stub.cpp
//  NeuraLink
//
//  Default stub implementation when no generated dataset is compiled in.
//

#include "vrm_motion_dataset.hpp"

namespace NeuraLink {

__attribute__((weak)) bool loadGeneratedDatabase(MotionDatabase& /*db*/) {
    return false;
}

} // namespace NeuraLink
