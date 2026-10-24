#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface AnyCastVirtualDisplay : NSObject
@property (nonatomic, readonly) CGDirectDisplayID displayID;
- (nullable instancetype)initWithName:(NSString *)name width:(uint32_t)width height:(uint32_t)height
                          refreshRate:(float)refreshRate productID:(uint32_t)productID error:(NSError **)error;
- (void)destroy;
@end

NS_ASSUME_NONNULL_END
