#import <AVFAudio/AVFAudio.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Single-worker streaming access to the BS.1770 implementation in pinned SFBAudioEngine.
@interface VolumeLoudnessMeter : NSObject
- (nullable instancetype)initWithFormat:(AVAudioFormat *)format error:(NSError **)error;
- (BOOL)appendBuffer:(AVAudioPCMBuffer *)buffer error:(NSError **)error NS_SWIFT_NAME(append(_:));
- (nullable NSNumber *)gainWithError:(NSError **)error NS_SWIFT_NAME(gain());
@property(nonatomic, readonly) double peak;
+ (nullable NSNumber *)albumGainForMeters:(NSArray<VolumeLoudnessMeter *> *)meters error:(NSError **)error NS_SWIFT_NAME(albumGain(for:));
@end
NS_ASSUME_NONNULL_END
