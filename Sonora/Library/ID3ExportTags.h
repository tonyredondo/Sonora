#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Retains export metadata that the audio metadata adapter does not write to ID3.
@interface ID3ExportTags : NSObject
+ (BOOL)writeValues:(NSDictionary<NSString *, NSArray<NSString *> *> *)values toURL:(NSURL *)url error:(NSError **)error NS_SWIFT_NAME(write(_:to:));
+ (nullable NSDictionary<NSString *, NSArray<NSString *> *> *)readFromURL:(NSURL *)url error:(NSError **)error NS_SWIFT_NAME(read(from:));
@end
NS_ASSUME_NONNULL_END
