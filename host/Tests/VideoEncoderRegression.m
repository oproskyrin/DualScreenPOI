#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import "VTEncoderShim.h"
#include <assert.h>

@interface Packets : NSObject
@property NSMutableArray<NSData *> *data;
@property NSMutableArray<NSNumber *> *keys;
@property dispatch_semaphore_t ready;
@end
@implementation Packets
@end
static void packet(void *ctx, const uint8_t *bytes, size_t count, double pts, int key) {
    Packets *p = (__bridge Packets *)ctx;
    @synchronized(p) { [p.data addObject:[NSData dataWithBytes:bytes length:count]]; [p.keys addObject:@(key)]; }
    dispatch_semaphore_signal(p.ready);
}
static void decoded(void *ctx, void *source, OSStatus status, VTDecodeInfoFlags flags,
                    CVImageBufferRef image, CMTime pts, CMTime duration) {
    assert(status == noErr && image != NULL);
    assert(CVPixelBufferGetWidth(image) == 320 && CVPixelBufferGetHeight(image) == 240);
    dispatch_semaphore_signal((dispatch_semaphore_t)(__bridge id)ctx);
}
static NSArray<NSData *> *nals(NSData *data) {
    const uint8_t *b = data.bytes;
    NSMutableArray *out = [NSMutableArray array];
    size_t start = 0;
    for (size_t i = 0; i + 4 <= data.length; i++) {
        if (b[i] == 0 && b[i+1] == 0 && b[i+2] == 0 && b[i+3] == 1) {
            if (start) [out addObject:[data subdataWithRange:NSMakeRange(start, i-start)]];
            start = i+4; i += 3;
        }
    }
    if (start < data.length) [out addObject:[data subdataWithRange:NSMakeRange(start, data.length-start)]];
    return out;
}
static void check(int codec, BOOL legacy) {
    Packets *p = [Packets new]; p.data = [NSMutableArray array]; p.keys = [NSMutableArray array];
    p.ready = dispatch_semaphore_create(0);
    void *enc = legacy ? vtenc_create(320, 240, 30, 2000000, packet, (__bridge void *)p)
        : vtenc_create_codec(320, 240, 30, 2000000, codec, packet, (__bridge void *)p);
    assert(enc != NULL);
    CVPixelBufferRef pix = NULL;
    NSDictionary *attrs = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
    assert(CVPixelBufferCreate(NULL, 320, 240, kCVPixelFormatType_32BGRA,
                              (__bridge CFDictionaryRef)attrs, &pix) == kCVReturnSuccess);
    CVPixelBufferLockBaseAddress(pix, 0);
    memset(CVPixelBufferGetBaseAddress(pix), 100, CVPixelBufferGetBytesPerRow(pix)*240);
    CVPixelBufferUnlockBaseAddress(pix, 0);
    for (int i = 0; i < 3; i++) assert(vtenc_encode(enc, pix, i/30.0, i != 1) == 0);
    for (int i = 0; i < 3; i++) assert(dispatch_semaphore_wait(p.ready, dispatch_time(DISPATCH_TIME_NOW, 10*NSEC_PER_SEC)) == 0);
    vtenc_destroy(enc); CVPixelBufferRelease(pix);
    NSArray *packets; NSArray *keys;
    @synchronized(p) { packets = [p.data copy]; keys = [p.keys copy]; }
    assert(packets.count == 3);
    for (NSUInteger frame = 0; frame < packets.count; frame++) {
        NSArray<NSData *> *units = nals(packets[frame]);
        NSMutableDictionary<NSNumber *, NSData *> *sets = [NSMutableDictionary dictionary];
        NSMutableData *avcc = [NSMutableData data]; BOOL idr = NO;
        for (NSData *nal in units) {
            const uint8_t *b = nal.bytes;
            int type = codec == VTENC_CODEC_H264 ? b[0]&31 : (b[0]>>1)&63;
            BOOL parameter = codec == VTENC_CODEC_H264 ? (type == 7 || type == 8) : (type >= 32 && type <= 34);
            if (parameter) sets[@(type)] = nal;
            else { uint32_t len = CFSwapInt32HostToBig((uint32_t)nal.length); [avcc appendBytes:&len length:4]; [avcc appendData:nal]; }
            if (codec == VTENC_CODEC_H264 ? type == 5 : (type == 19 || type == 20)) idr = YES;
        }
        if (![keys[frame] boolValue]) continue;
        assert(idr);
        size_t count = codec == VTENC_CODEC_H264 ? 2 : 3;
        const uint8_t *ptrs[3]; size_t sizes[3];
        for (size_t i = 0; i < count; i++) {
            NSData *set = sets[@((codec == VTENC_CODEC_H264 ? 7 : 32)+(int)i)];
            assert(set.length > 0); ptrs[i] = set.bytes; sizes[i] = set.length;
        }
        CMVideoFormatDescriptionRef format = NULL;
        OSStatus status = codec == VTENC_CODEC_H264
            ? CMVideoFormatDescriptionCreateFromH264ParameterSets(NULL, count, ptrs, sizes, 4, &format)
            : CMVideoFormatDescriptionCreateFromHEVCParameterSets(NULL, count, ptrs, sizes, 4, NULL, &format);
        assert(status == noErr);
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        VTDecompressionOutputCallbackRecord cb = {decoded, (__bridge void *)done};
        VTDecompressionSessionRef decoder = NULL;
        assert(VTDecompressionSessionCreate(NULL, format, NULL, NULL, &cb, &decoder) == noErr);
        CMBlockBufferRef block = NULL;
        assert(CMBlockBufferCreateWithMemoryBlock(NULL, NULL, avcc.length, NULL, NULL, 0, avcc.length, 0, &block) == noErr);
        assert(CMBlockBufferReplaceDataBytes(avcc.bytes, block, 0, avcc.length) == noErr);
        CMSampleBufferRef sample = NULL; size_t size = avcc.length;
        assert(CMSampleBufferCreateReady(NULL, block, format, 1, 0, NULL, 1, &size, &sample) == noErr);
        assert(VTDecompressionSessionDecodeFrame(decoder, sample, 0, NULL, NULL) == noErr);
        VTDecompressionSessionWaitForAsynchronousFrames(decoder);
        assert(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC)) == 0);
        VTDecompressionSessionInvalidate(decoder);
        CFRelease(decoder); CFRelease(sample); CFRelease(block); CFRelease(format);
    }
    assert([keys[0] boolValue] && [keys[2] boolValue]);
    printf("PASS %s%s: 3 encoded frames, forced keyframes with parameter sets decoded via VT\n", codec == VTENC_CODEC_H264 ? "h264" : "hevc", legacy ? " legacy" : "");
}
int main(void) { @autoreleasepool {
    check(VTENC_CODEC_HEVC, YES);
    check(VTENC_CODEC_H264, NO);
    assert(vtenc_create_codec(320, 240, 30, 2000000, 999, packet, NULL) == NULL);
    assert(vtenc_create_codec(0, 240, 30, 2000000, VTENC_CODEC_H264, packet, NULL) == NULL);
} return 0; }
