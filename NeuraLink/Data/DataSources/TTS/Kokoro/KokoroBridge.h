#import <Foundation/Foundation.h>

@interface KokoroBridge : NSObject

- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                                voicesPath:(NSString *)voicesPath
                                 vocabPath:(NSString *)vocabPath
                                  dictPath:(NSString *)dictPath;

- (nullable NSData *)synthesizeText:(NSString *)text
                          voiceName:(NSString *)voiceName
                              speed:(float)speed
                              error:(NSError **)error;

@end
