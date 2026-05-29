#import "KokoroBridge.h"
#include "Kokoro.h"

@implementation KokoroBridge {
    std::unique_ptr<Kokoro> _kokoro;
}

- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                                voicesPath:(NSString *)voicesPath
                                 vocabPath:(NSString *)vocabPath
                                  dictPath:(NSString *)dictPath
                            intraOpThreads:(int)intraOpThreads {
    self = [super init];
    if (self) {
        try {
            _kokoro = std::make_unique<Kokoro>(
                [modelPath UTF8String],
                [voicesPath UTF8String],
                [vocabPath UTF8String],
                [dictPath UTF8String],
                intraOpThreads
            );
        } catch (const std::exception &e) {
            NSLog(@"[KokoroBridge] Error initializing Kokoro: %s", e.what());
            return nil;
        }
    }
    return self;
}

- (BOOL)synthesizeStreamingText:(NSString *)text
                      voiceName:(NSString *)voiceName
                          speed:(float)speed
                        onBatch:(void (^)(NSData *batchPCM))onBatch
                          error:(NSError **)error {
    if (!_kokoro) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.dedicatus.NeuraLink.Kokoro"
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Engine not initialized"}];
        }
        return NO;
    }

    try {
        _kokoro->create_streaming(
            [text UTF8String],
            [voiceName UTF8String],
            speed,
            false, // is_phonemes
            true,  // trim
            [onBatch](const float* samples, size_t count) {
                if (!onBatch || count == 0) return;
                NSData *pcm = [NSData dataWithBytes:samples
                                             length:count * sizeof(float)];
                onBatch(pcm);
            }
        );
        return YES;
    } catch (const std::exception &e) {
        if (error) {
            NSString *msg = [NSString stringWithUTF8String:e.what()];
            *error = [NSError errorWithDomain:@"com.dedicatus.NeuraLink.Kokoro"
                                         code:-2
                                     userInfo:@{NSLocalizedDescriptionKey: msg}];
        }
        return NO;
    }
}

@end
