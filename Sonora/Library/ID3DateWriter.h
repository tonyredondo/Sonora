#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Preserves reduced-precision ISO dates which the upstream metadata adapter rejects.
@interface ID3DateWriter : NSObject
+ (BOOL)writeDate:(NSString *)date toURL:(NSURL *)url error:(NSError **)error NS_SWIFT_NAME(write(_:to:));
@end
NS_ASSUME_NONNULL_END
