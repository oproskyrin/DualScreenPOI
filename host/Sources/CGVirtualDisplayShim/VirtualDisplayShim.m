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
    // High PPI (laptop-class pixel density) so macOS synthesizes HiDPI @2x
    // display modes; at low PPI it assumes 1x is enough.
    double ppi = 220.0;
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
    // force-hidpi technique: with hiDPI=1 the compositor treats the declared
    // mode size as POINTS and renders with a 2x pixel backing store, as long
    // as maxPixels == mode * 2 and the mode list stays simple (full-res
    // extra modes break the @2x selection).
    //   hiDPI:     mode 1472x920 (points) -> 2944x1840 pixels
    //   !hiDPI:    mode 2944x1840 -> 2944x1840 pixels (1:1)
    if (hiDPI) {
        for (size_t i = 0; i < rateCount; i++) {
            [modes addObject:[[CGVirtualDisplayMode alloc] initWithWidth:pixelW / 2 height:pixelH / 2 refreshRate:rates[i]]];
        }
    } else {
        for (size_t i = 0; i < rateCount; i++) {
            [modes addObject:[[CGVirtualDisplayMode alloc] initWithWidth:pixelW height:pixelH refreshRate:rates[i]]];
        }
    }
    // (No extra "standard" sizes: a clean list is required for the @2x
    // selection; the extend-vs-mirror prompt is handled by the unmirror
    // guard in main.swift.)
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
