#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "VirtualDisplayShim.h"

// Private CoreGraphics classes (no public headers). Same technique as
// DeskPad / BetterDummy / hidpi-mirror. Signatures verified against
// macOS 26/27 runtime; if a macOS update breaks creation, fix here first.

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int vendorID;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic, strong) dispatch_queue_t queue;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic) unsigned int hiDPI;
@property (nonatomic, strong) NSArray *modes;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property (nonatomic, readonly) unsigned int displayID;
@end

static CGVirtualDisplay *_vd = nil;

uint32_t vd_create_display(uint32_t pixelW, uint32_t pixelH,
                           const double *rates, size_t rateCount,
                           bool hiDPI,
                           uint32_t vendorID, uint32_t productID, uint32_t serial,
                           const char *name) {
    if (_vd != nil) return 0;

    CGVirtualDisplayDescriptor *descriptor = [[CGVirtualDisplayDescriptor alloc] init];
    // ~110 PPI so the reported physical size looks like a real panel; this
    // makes macOS default to the native mode instead of a scaled one.
    double ppi = 110.0;
    descriptor.sizeInMillimeters = CGSizeMake(25.4 * pixelW / ppi, 25.4 * pixelH / ppi);
    descriptor.maxPixelsWide = pixelW;   // must match the top mode exactly
    descriptor.maxPixelsHigh = pixelH;
    descriptor.name = name != NULL ? [NSString stringWithUTF8String:name] : @"DualScreen";
    descriptor.vendorID = vendorID;      // non-zero required (0 -> init returns nil)
    descriptor.productID = productID;
    descriptor.serialNum = serial;
    descriptor.queue = dispatch_get_main_queue();

    CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
    if (display == nil) {
        fprintf(stderr, "[vd] initWithDescriptor failed\n");
        return 0;
    }

    CGVirtualDisplaySettings *settings = [[CGVirtualDisplaySettings alloc] init];
    settings.hiDPI = hiDPI ? 1 : 0;

    NSMutableArray *modes = [NSMutableArray array];
    // Full-resolution modes first (first entry becomes the active mode).
    for (size_t i = 0; i < rateCount; i++) {
        [modes addObject:[[CGVirtualDisplayMode alloc] initWithWidth:pixelW height:pixelH refreshRate:rates[i]]];
    }
    // Half-resolution (HiDPI "looks like") ladder.
    if (pixelW / 2 >= 640 && pixelH / 2 >= 480) {
        for (size_t i = 0; i < rateCount; i++) {
            [modes addObject:[[CGVirtualDisplayMode alloc] initWithWidth:pixelW / 2 height:pixelH / 2 refreshRate:rates[i]]];
        }
    }
    // A couple of standard-ish sizes so macOS heuristics read this as a
    // computer monitor, not a TV (avoids the "mirror by default" picker).
    const CGSize stdSizes[] = { CGSizeMake(2560, 1600) };
    for (size_t i = 0; i < sizeof(stdSizes) / sizeof(stdSizes[0]); i++) {
        CGSize s = stdSizes[i];
        if (s.width < pixelW && s.height < pixelH) {
            [modes addObject:[[CGVirtualDisplayMode alloc] initWithWidth:(unsigned int)s.width height:(unsigned int)s.height refreshRate:rates[0]]];
            [modes addObject:[[CGVirtualDisplayMode alloc] initWithWidth:(unsigned int)s.width height:(unsigned int)s.height refreshRate:60.0]];
        }
    }
    settings.modes = modes;

    BOOL ok = [display applySettings:settings];
    if (!ok) {
        fprintf(stderr, "[vd] applySettings failed\n");
        // Display object still live; drop it.
        CFRelease((__bridge CFTypeRef)display);
        return 0;
    }

    uint32_t displayID = display.displayID;
    if (displayID == 0 || displayID == kCGNullDirectDisplay) {
        fprintf(stderr, "[vd] null displayID\n");
        CFRelease((__bridge CFTypeRef)display);
        return 0;
    }

    _vd = display; // strong ref: display lives as long as the object is retained
    return displayID;
}

void vd_release_display(void) {
    if (_vd != nil) {
        CFRelease((__bridge CFTypeRef)_vd);
        _vd = nil;
    }
}
