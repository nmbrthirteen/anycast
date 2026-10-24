#import "VirtualDisplayKit.h"
#import <dlfcn.h>

typedef struct { float a, b; } AnyCastFloatPair;
typedef struct { uint32_t a, b; } AnyCastSize;
typedef struct { AnyCastFloatPair red, green, blue, white; } AnyCastChromaticities;

// SkyLight's virtual display classes are private; these declarations match their runtime type encodings on macOS 26 and 27.
@interface NSObject (AnyCastSkyLight)
- (id)initWithName:(NSString *)name vendorID:(uint64_t)vendor productID:(uint64_t)product serialNumber:(uint64_t)serial
 sizeInMillimeters:(AnyCastFloatPair)millimeters maximumSizeInPixels:(AnyCastSize)pixels
    chromaticities:(AnyCastChromaticities)chromaticities error:(NSError **)error;
- (void)setOptions:(uint64_t)options;
- (id)initWithSizeInPixels:(AnyCastSize)pixels sizeInPoints:(AnyCastSize)points refreshRate:(float)rate error:(NSError **)error;
- (id)initWithNativeMode:(id)native preferredMode:(id)preferred optionalModes:(NSArray *)optional rotations:(uint64_t)rotations error:(NSError **)error;
- (id)initWithConfiguration:(id)configuration error:(NSError **)error;
- (BOOL)applySettings:(id)settings error:(NSError **)error;
- (uint32_t)displayID;
- (void)destroy;
@end

// Bit 4 asks WindowServer to extend the desktop onto the display. Bits 1 and 64 take over the built-in screen, so they are never set.
static const uint64_t AnyCastExtendOption = 4;

@implementation AnyCastVirtualDisplay {
    id _display;
}

- (nullable instancetype)initWithName:(NSString *)name width:(uint32_t)width height:(uint32_t)height
                          refreshRate:(float)refreshRate productID:(uint32_t)productID error:(NSError **)error {
    if (!(self = [super init])) return nil;
    dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW);
    Class configurationClass = NSClassFromString(@"SLVirtualDisplayConfiguration");
    Class modeClass = NSClassFromString(@"SLVirtualDisplayMode");
    Class settingsClass = NSClassFromString(@"SLVirtualDisplaySettings");
    Class displayClass = NSClassFromString(@"SLVirtualDisplay");
    if (!configurationClass || !modeClass || !settingsClass || !displayClass) {
        if (error) *error = [NSError errorWithDomain:@"AnyCast" code:1 userInfo:@{NSLocalizedDescriptionKey: @"This macOS version can't create a TV screen."}];
        return nil;
    }
    AnyCastChromaticities srgb = {{0.64f, 0.33f}, {0.30f, 0.60f}, {0.15f, 0.06f}, {0.3127f, 0.3290f}};
    float inchesWide = 48.0f;
    AnyCastFloatPair millimeters = {inchesWide * 25.4f, inchesWide * 25.4f * height / width};
    id configuration = [[configurationClass alloc] initWithName:name vendorID:0x5043 productID:productID serialNumber:productID
                                              sizeInMillimeters:millimeters maximumSizeInPixels:(AnyCastSize){width, height}
                                                 chromaticities:srgb error:error];
    if (!configuration) return nil;
    [configuration setOptions:AnyCastExtendOption];

    id mode = [[modeClass alloc] initWithSizeInPixels:(AnyCastSize){width, height} sizeInPoints:(AnyCastSize){width, height} refreshRate:refreshRate error:error];
    if (!mode) return nil;
    id settings = [[settingsClass alloc] initWithNativeMode:mode preferredMode:mode optionalModes:@[] rotations:0 error:error];
    if (!settings) return nil;
    _display = [[displayClass alloc] initWithConfiguration:configuration error:error];
    if (!_display || ![_display applySettings:settings error:error]) {
        [self destroy];
        return nil;
    }
    return self;
}

- (CGDirectDisplayID)displayID {
    return _display ? [_display displayID] : kCGNullDirectDisplay;
}

- (void)destroy {
    if ([_display respondsToSelector:@selector(destroy)]) [_display destroy];
    _display = nil;
}

- (void)dealloc {
    [self destroy];
}
@end
