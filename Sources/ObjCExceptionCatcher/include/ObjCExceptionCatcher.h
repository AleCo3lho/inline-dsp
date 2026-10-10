#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// AVAudioEngine reports many graph misconfigurations (e.g. a format that no longer matches the
/// hardware after a device change) by raising an NSException, which Swift cannot catch and which
/// would otherwise terminate the process. Running such calls through here turns the exception
/// into a Swift error so the caller can back off and retry.
@interface ObjCExceptionCatcher : NSObject
+ (BOOL)catching:(NS_NOESCAPE void (^)(void))block error:(NSError * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
