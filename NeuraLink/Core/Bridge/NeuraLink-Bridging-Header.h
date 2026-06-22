//
//  NeuraLink-Bridging-Header.h
//  NeuraLink
//
//  Exposes the pure-C llama_bridge API to Swift.
//  C++ symbols in llama_bridge.cpp are never visible here.
//
//  Xcode Build Setting:
//    SWIFT_OBJC_BRIDGING_HEADER = NeuraLink/Bridge/NeuraLink-Bridging-Header.h
//

#ifndef NeuraLink_Bridging_Header_h
#define NeuraLink_Bridging_Header_h

#include "llama_bridge.h"
#include "whisper_bridge.h"
#include "openvoice_bridge.h"
#include "../../Dependencies/VOICEVOX/voicevox_core.xcframework/ios-arm64/voicevox_core.framework/Headers/voicevox_core.h"
#import "KokoroBridge.h"

#endif /* NeuraLink_Bridging_Header_h */
