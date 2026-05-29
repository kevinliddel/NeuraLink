#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface KokoroBridge : NSObject

- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                                voicesPath:(NSString *)voicesPath
                                 vocabPath:(NSString *)vocabPath
                                  dictPath:(NSString *)dictPath
                            intraOpThreads:(int)intraOpThreads;

/// Streaming synthesis: invokes `onBatch` once per phoneme batch as PCM
/// becomes available. Returns YES on success, NO with `error` set on failure.
- (BOOL)synthesizeStreamingText:(NSString *)text
                      voiceName:(NSString *)voiceName
                          speed:(float)speed
                        onBatch:(void (^)(NSData *batchPCM))onBatch
                          error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
