#import "KokoroBridge.h"
#include "Kokoro.h"

@implementation KokoroBridge {
    std::unique_ptr<Kokoro> _kokoro;
}

- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                                voicesPath:(NSString *)voicesPath
                                 vocabPath:(NSString *)vocabPath
                                  dictPath:(NSString *)dictPath {
    self = [super init];
    if (self) {
        try {
            _kokoro = std::make_unique<Kokoro>(
                [modelPath UTF8String],
                [voicesPath UTF8String],
                [vocabPath UTF8String],
                [dictPath UTF8String]
            );
        } catch (const std::exception &e) {
            NSLog(@"[KokoroBridge] Error initializing Kokoro: %s", e.what());
            return nil;
        }
    }
    return self;
}

- (nullable NSData *)synthesizeText:(NSString *)text
                          voiceName:(NSString *)voiceName
                              speed:(float)speed
                              error:(NSError **)error {
    if (!_kokoro) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.dedicatus.NeuraLink.Kokoro"
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Engine not initialized"}];
        }
        return nil;
    }
    
    try {
        auto result = _kokoro->create(
            [text UTF8String],
            [voiceName UTF8String],
            speed,
            false, // is_phonemes
            true   // trim
        );
        
        const auto& audio = result.first;
        return [NSData dataWithBytes:audio.data() length:audio.size() * sizeof(float)];
    } catch (const std::exception &e) {
        if (error) {
            NSString *msg = [NSString stringWithUTF8String:e.what()];
            *error = [NSError errorWithDomain:@"com.dedicatus.NeuraLink.Kokoro"
                                         code:-2
                                     userInfo:@{NSLocalizedDescriptionKey: msg}];
        }
        return nil;
    }
}

@end
