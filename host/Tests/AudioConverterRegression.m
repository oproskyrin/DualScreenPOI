#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <AudioToolbox/AudioToolbox.h>
#import "VTEncoderShim.h"

// Synthesized noninterleaved float stereo, matching ScreenCaptureKit output.
int main(void) {
    AudioStreamBasicDescription format = {
        48000, kAudioFormatLinearPCM,
        kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
        4, 1, 4, 2, 32, 0
    };
    CMAudioFormatDescriptionRef description = NULL;
    if (CMAudioFormatDescriptionCreate(NULL, &format, 0, NULL, 0, NULL, NULL, &description)) return 2;
    float left[480], right[480];
    for (int i = 0; i < 480; i++) { left[i] = 0.25f; right[i] = -0.5f; }
    struct { UInt32 count; AudioBuffer buffers[2]; } buffers = {
        2, {{1, sizeof(left), left}, {1, sizeof(right), right}}
    };
    CMSampleTimingInfo timing = {CMTimeMake(1, 48000), kCMTimeZero, kCMTimeInvalid};
    CMSampleBufferRef sample = NULL;
    if (CMSampleBufferCreate(NULL, NULL, false, NULL, NULL, description,
                            480, 1, &timing, 0, NULL, &sample)) return 3;
    if (CMSampleBufferSetDataBufferFromAudioBufferList(sample, NULL, NULL, 0,
                                                       (AudioBufferList *)&buffers)) return 4;
    CMSampleBufferSetDataReady(sample);
    int16_t output[960] = {0};
    size_t written = vtaudio_pcm16_stereo(sample, output, 960);
    printf("samples=%zu left=%d right=%d\n", written, output[0], output[1]);
    BOOL valid = written == 960;
    for (size_t i = 0; valid && i < written; i += 2) {
        valid = output[i] == 8191 && output[i + 1] == -16383;
    }
    valid = valid && vtaudio_pcm16_stereo(sample, output, 1) == 0;
    valid = valid && vtaudio_pcm16_stereo(NULL, output, 960) == 0;
    CFRelease(sample);
    CFRelease(description);
    return valid ? 0 : 1;
}
