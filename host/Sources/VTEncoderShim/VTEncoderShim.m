#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import "VTEncoderShim.h"

typedef struct {
    VTCompressionSessionRef session;
    vtenc_packet_cb cb;
    void *ctx;
} vtenc;

static CFNumberRef numInt(int64_t v) {
    return CFNumberCreate(NULL, kCFNumberSInt64Type, &v);
}
static CFNumberRef numDouble(double v) {
    return CFNumberCreate(NULL, kCFNumberDoubleType, &v);
}

static OSStatus setNum(VTCompressionSessionRef s, CFStringRef key, CFNumberRef num) {
    OSStatus err = VTSessionSetProperty(s, key, num);
    CFRelease(num);
    return err;
}

static void packet_cb(void *outputCallbackRefCon,
                      void *sourceFrameRefCon,
                      OSStatus status,
                      VTEncodeInfoFlags infoFlags,
                      CMSampleBufferRef sampleBuffer) {
    (void)sourceFrameRefCon; (void)infoFlags;
    vtenc *enc = (vtenc *)outputCallbackRefCon;
    if (status != noErr || sampleBuffer == NULL) return;
    if (enc == NULL || enc->cb == NULL) return;

    Boolean isKey = true;
    CFArrayRef atts = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    if (atts != NULL && CFArrayGetCount(atts) > 0) {
        CFDictionaryRef att = (CFDictionaryRef)CFArrayGetValueAtIndex(atts, 0);
        CFTypeRef dep = CFDictionaryGetValue(att, kCMSampleAttachmentKey_DependsOnOthers);
        if (dep != NULL) {
            Boolean depends = 0;
            if (CFGetTypeID(dep) == CFBooleanGetTypeID()) {
                depends = CFBooleanGetValue((CFBooleanRef)dep);
            } else if (CFGetTypeID(dep) == CFNumberGetTypeID()) {
                int v = 0; CFNumberGetValue((CFNumberRef)dep, kCFNumberIntType, &v);
                depends = v != 0;
            }
            isKey = !depends;
        }
    }

    CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(sampleBuffer);
    CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (fd == NULL || bb == NULL) return;

    NSMutableData *out = [NSMutableData data];
    static const UInt8 startCode[4] = {0x00, 0x00, 0x00, 0x01};

    if (isKey) {
        // Iterate all parameter sets (VPS/SPS/PPS, possibly SEI) from the
        // HEVC decoder configuration record. NOTE: the last parameter is
        // NALUnitHeaderLengthOut (length-field size), NOT the NAL type.
        for (size_t i = 0; i < 8; i++) {
            const uint8_t *ptr = NULL;
            size_t size = 0;
            if (CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    fd, i, &ptr, &size, NULL, NULL) != noErr || ptr == NULL) break;
            [out appendBytes:startCode length:4];
            [out appendBytes:ptr length:size];
        }
    }

    // HVCC (4-byte length prefixed NALs) -> Annex B
    size_t total = CMBlockBufferGetDataLength(bb);
    size_t offset = 0;
    uint8_t stack[512];
    while (offset + 4 <= total) {
        uint32_t beLen = 0;
        if (CMBlockBufferCopyDataBytes(bb, offset, 4, &beLen) != noErr) break;
        uint32_t nalLen = CFSwapInt32BigToHost(beLen);
        if (nalLen == 0 || offset + 4 + nalLen > total) break;
        size_t outLenBefore = out.length;
        [out appendBytes:startCode length:4];
        size_t copied = 0;
        BOOL ok = YES;
        while (copied < nalLen) {
            size_t chunk = (nalLen - copied < sizeof(stack)) ? (nalLen - copied) : sizeof(stack);
            if (CMBlockBufferCopyDataBytes(bb, offset + 4 + copied, chunk, stack) != noErr) {
                ok = NO;
                break;
            }
            [out appendBytes:stack length:chunk];
            copied += chunk;
        }
        if (!ok) {
            [out setLength:outLenBefore];
            break;
        }
        offset += 4 + nalLen;
    }

    if (out.length > 0) {
        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        double ptsSec = (double)pts.value / (double)pts.timescale;
        enc->cb(enc->ctx, out.bytes, out.length, ptsSec, isKey ? 1 : 0);
    }
}

void *vtenc_create(uint32_t width, uint32_t height,
                   uint32_t fps, uint32_t bitrateBps,
                   vtenc_packet_cb cb, void *ctx) {
    vtenc *enc = malloc(sizeof(vtenc));
    if (enc == NULL) return NULL;
    memset(enc, 0, sizeof(vtenc));
    enc->cb = cb;
    enc->ctx = ctx;

    OSStatus err = VTCompressionSessionCreate(
        NULL, (int32_t)width, (int32_t)height,
        kCMVideoCodecType_HEVC, NULL, NULL, NULL,
        packet_cb, enc, &enc->session);
    if (err != noErr || enc->session == NULL) {
        fprintf(stderr, "[vtenc] session create failed: %d\n", err);
        free(enc);
        return NULL;
    }

    VTSessionSetProperty(enc->session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(enc->session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    VTSessionSetProperty(enc->session, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel);
    setNum(enc->session, kVTCompressionPropertyKey_MaxFrameDelayCount, numInt(0));
    setNum(enc->session, kVTCompressionPropertyKey_MaxKeyFrameInterval, numInt((int64_t)fps * 2));
    setNum(enc->session, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, numDouble(2.0));
    setNum(enc->session, kVTCompressionPropertyKey_ExpectedFrameRate, numInt((int64_t)fps));
    setNum(enc->session, kVTCompressionPropertyKey_AverageBitRate, numInt((int64_t)bitrateBps));
    CFNumberRef limNums[2] = {numInt(0), numInt((int64_t)bitrateBps * 3 / 2)};
    CFArrayRef limits = CFArrayCreate(NULL, (const void **)limNums, 2, &kCFTypeArrayCallBacks);
    VTSessionSetProperty(enc->session, kVTCompressionPropertyKey_DataRateLimits, limits);
    CFRelease(limits); CFRelease(limNums[0]); CFRelease(limNums[1]);

    VTCompressionSessionPrepareToEncodeFrames(enc->session);
    return enc;
}

int vtenc_encode(void *opaque, CVPixelBufferRef pix, double ptsSeconds, int forceKeyframe) {
    vtenc *enc = (vtenc *)opaque;
    if (enc == NULL || enc->session == NULL) return -1;
    CMTime pts = CMTimeMake((int64_t)(ptsSeconds * 1000000.0), 1000000);
    CFDictionaryRef props = NULL;
    if (forceKeyframe) {
        const void *keys[] = {kVTEncodeFrameOptionKey_ForceKeyFrame};
        const void *vals[] = {kCFBooleanTrue};
        props = CFDictionaryCreate(NULL, keys, vals, 1,
                                   &kCFTypeDictionaryKeyCallBacks,
                                   &kCFTypeDictionaryValueCallBacks);
    }
    OSStatus err = VTCompressionSessionEncodeFrame(
        enc->session, pix, pts, kCMTimeInvalid, props, NULL, NULL);
    if (props) CFRelease(props);
    return err == noErr ? 0 : (int)err;
}

void vtenc_destroy(void *opaque) {
    vtenc *enc = (vtenc *)opaque;
    if (enc == NULL) return;
    if (enc->session != NULL) {
        VTCompressionSessionInvalidate(enc->session);
        CFRelease(enc->session);
    }
    free(enc);
}

// ---- audio: CMSampleBuffer -> interleaved PCM16 LE 48k stereo ----
// (CMSampleBufferGetAudioBufferList is not exposed to Swift on macOS 27,
// so the whole conversion lives here.)

size_t vtaudio_pcm16_stereo(CMSampleBufferRef sb, int16_t *outBuf, size_t outCapacitySamples) {
    if (sb == NULL) return 0;
    CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(sb);
    if (fd == NULL) return 0;
    const AudioStreamBasicDescription *asbd =
        CMAudioFormatDescriptionGetStreamBasicDescription(fd);
    if (asbd == NULL || (asbd->mFormatFlags & kAudioFormatFlagIsFloat) == 0) return 0;

    CMItemCount frames = CMSampleBufferGetNumSamples(sb);
    if (frames <= 0) return 0;
    size_t need = (size_t)frames * 2; // interleaved stereo
    if (need > outCapacitySamples) return 0;

    size_t sizeRequired = 0;
    CMBlockBufferRef blockBuffer = NULL;
    if (CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, &sizeRequired, NULL, 0,
            NULL, NULL, 0, &blockBuffer) != noErr ||
        sizeRequired == 0 || blockBuffer == NULL) {
        return 0;
    }
    uint8_t *ablMem = malloc(sizeRequired);
    if (ablMem == NULL) {
        CFRelease(blockBuffer);
        return 0;
    }
    if (CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, NULL, (AudioBufferList *)ablMem, sizeRequired,
            NULL, NULL, 0, NULL) != noErr) {
        free(ablMem);
        CFRelease(blockBuffer);
        return 0;
    }

    const float *ch[2] = {NULL, NULL};
    AudioBufferList *abl = (AudioBufferList *)ablMem;
    int chanCount = 0;
    for (int i = 0; i < abl->mNumberBuffers; i++) {
        AudioBuffer *ab = &abl->mBuffers[i];
        if (ab->mNumberChannels > 0 && ab->mData != NULL && chanCount < 2) {
            ch[chanCount++] = (const float *)ab->mData;
        }
    }

    size_t written = 0;
    if (chanCount >= 1) {
        const float *l = ch[0];
        const float *r = (chanCount >= 2) ? ch[1] : ch[0];
        for (CMItemCount i = 0; i < frames; i++) {
            float ls = l[i], rs = r[i];
            if (ls > 1.0f) ls = 1.0f; else if (ls < -1.0f) ls = -1.0f;
            if (rs > 1.0f) rs = 1.0f; else if (rs < -1.0f) rs = -1.0f;
            outBuf[written++] = (int16_t)(ls * 32766.0f);
            outBuf[written++] = (int16_t)(rs * 32766.0f);
        }
    }
    free(ablMem);
    CFRelease(blockBuffer);
    return written;
}
