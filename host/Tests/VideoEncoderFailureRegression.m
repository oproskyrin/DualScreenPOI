#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import "VTEncoderShim.h"
#include <assert.h>

// Compile-time interposition in the test object only. Real VT sessions are
// created for partial-create and prepare failures to verify cleanup ownership.
static int mode, invalidated;
OSStatus test_vt_create(CFAllocatorRef allocator, int32_t width, int32_t height,
                       CMVideoCodecType codec, CFDictionaryRef spec,
                       CFDictionaryRef attrs, CFAllocatorRef buffers,
                       VTCompressionOutputCallback callback, void *context,
                       VTCompressionSessionRef *session) {
    if (mode == 0) { *session = NULL; return kVTVideoEncoderNotAvailableNowErr; }
    OSStatus result = VTCompressionSessionCreate(allocator, width, height, codec,
        spec, attrs, buffers, callback, context, session);
    assert(result == noErr && *session != NULL);
    return mode == 1 ? kVTVideoEncoderNotAvailableNowErr : result;
}
OSStatus test_vt_prepare(VTCompressionSessionRef session) {
    if (mode == 2) return kVTVideoEncoderNotAvailableNowErr;
    return VTCompressionSessionPrepareToEncodeFrames(session);
}
void test_vt_invalidate(VTCompressionSessionRef session) {
    invalidated++;
    VTCompressionSessionInvalidate(session);
}
int main(void) { @autoreleasepool {
    for (int codec = VTENC_CODEC_HEVC; codec <= VTENC_CODEC_H264; codec++) {
        for (mode = 0; mode < 3; mode++) {
            invalidated = 0;
            assert(vtenc_create_codec(320, 240, 30, 2000000, codec, NULL, NULL) == NULL);
            assert(invalidated == (mode == 0 ? 0 : 1));
        }
    }
    puts("PASS HEVC/H264 create, partial-create and prepare errors return NULL and release sessions");
} return 0; }
