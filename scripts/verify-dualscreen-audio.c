/* Offline verification only: loads the local bundle, never registers with HAL. */
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); exit(1); } } while (0)
static AudioServerPlugInDriverRef driver;
static AudioObjectPropertyAddress address(AudioObjectPropertySelector selector, AudioObjectPropertyScope scope) {
    return (AudioObjectPropertyAddress){selector, scope, kAudioObjectPropertyElementMain};
}
static UInt32 get(AudioObjectID object, AudioObjectPropertySelector selector, AudioObjectPropertyScope scope, void *data, UInt32 size) {
    UInt32 used = 0; AudioObjectPropertyAddress a = address(selector, scope);
    CHECK((*driver)->GetPropertyData(driver, object, 0, &a, 0, NULL, size, &used, data) == noErr);
    return used;
}
static void string_property(AudioObjectID object, AudioObjectPropertySelector selector, const char *expected) {
    CFStringRef value = NULL; char text[256];
    get(object, selector, kAudioObjectPropertyScopeGlobal, &value, sizeof(value));
    CHECK(value && CFStringGetCString(value, text, sizeof(text), kCFStringEncodingUTF8));
    printf("%s\n", text); CHECK(strcmp(text, expected) == 0); CFRelease(value);
}
int main(int argc, char **argv) {
    CHECK(argc == 2); void *bundle = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!bundle) { fprintf(stderr, "%s\n", dlerror()); return 1; }
    void *(*create)(CFAllocatorRef, CFUUIDRef) = dlsym(bundle, "BlackHole_Create");
    CHECK(create); driver = create(NULL, kAudioServerPlugInTypeUUID); CHECK(driver);
    string_property(3, kAudioObjectPropertyName, "Xiaoxin Pad Pro 12.7");
    string_property(3, kAudioDevicePropertyDeviceUID, "DualScreenAudio_UID");
    Float64 rate = 0; get(3, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, &rate, sizeof(rate)); CHECK(rate == 48000);
    AudioValueRange ranges[16]; UInt32 used = get(3, kAudioDevicePropertyAvailableNominalSampleRates, kAudioObjectPropertyScopeGlobal, ranges, sizeof(ranges));
    CHECK(used == sizeof(AudioValueRange) && ranges[0].mMinimum == 48000 && ranges[0].mMaximum == 48000);
    AudioStreamBasicDescription format;
    get(7, kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, &format, sizeof(format));
    CHECK(format.mSampleRate == 48000 && format.mChannelsPerFrame == 2);
    puts("PASS stereo; nominal and only supported sample rate = 48000 Hz");
    UInt32 hidden; get(3, kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal, &hidden, sizeof(hidden)); CHECK(!hidden);
    get(12, kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal, &hidden, sizeof(hidden)); CHECK(hidden);
    AudioObjectID streams[8]; used = get(12, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeGlobal, streams, sizeof(streams)); CHECK(used == 0);
    puts("PASS main visible; secondary hidden with no streams");
    AudioObjectID controls[16]; used = get(3, kAudioObjectPropertyControlList, kAudioObjectPropertyScopeOutput, controls, sizeof(controls));
    int volume = 0, mute = 0; for (UInt32 i = 0; i < used / sizeof(*controls); i++) { volume |= controls[i] == 8; mute |= controls[i] == 9; }
    CHECK(volume && mute);
    for (int id = 8; id <= 9; id++) {
        UInt32 scope = 0, element = 999;
        get(id, kAudioControlPropertyScope, kAudioObjectPropertyScopeGlobal, &scope, sizeof(scope));
        get(id, kAudioControlPropertyElement, kAudioObjectPropertyScopeGlobal, &element, sizeof(element));
        CHECK(scope == kAudioObjectPropertyScopeOutput && element == kAudioObjectPropertyElementMain);
    }
    Float32 scalar = -1, db = 1; UInt32 muted = 9;
    get(8, kAudioLevelControlPropertyScalarValue, kAudioObjectPropertyScopeGlobal, &scalar, sizeof(scalar));
    get(8, kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal, &db, sizeof(db));
    get(9, kAudioBooleanControlPropertyValue, kAudioObjectPropertyScopeGlobal, &muted, sizeof(muted));
    CHECK(scalar == 1 && db == 0 && muted == 0);
    puts("PASS output/main control scope and element; scalar=1 dB=0 mute=0");
    AudioObjectPropertyAddress a = address(kAudioLevelControlPropertyScalarValue, kAudioObjectPropertyScopeGlobal);
    Boolean writable = false; CHECK((*driver)->HasProperty(driver, 8, 0, &a));
    CHECK((*driver)->IsPropertySettable(driver, 8, 0, &a, &writable) == noErr && writable);
    a = address(kAudioBooleanControlPropertyValue, kAudioObjectPropertyScopeGlobal);
    CHECK((*driver)->HasProperty(driver, 9, 0, &a));
    CHECK((*driver)->IsPropertySettable(driver, 9, 0, &a, &writable) == noErr && writable);
    puts("PASS native output master volume and mute controls exposed and writable");
    a = address(kAudioDevicePropertyIcon, kAudioObjectPropertyScopeGlobal);
    CHECK(!(*driver)->HasProperty(driver, 3, 0, &a));
    puts("PASS no custom/BlackHole icon property; offline verification complete");
    return 0;
}
