/* Offline verification only: loads the local bundle, never registers with HAL. */
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <notify.h>
#include <libproc.h>
#include <unistd.h>
#include <signal.h>
#include <sys/wait.h>
#include <stdatomic.h>
#include <mach/mach_time.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); exit(1); } } while (0)
static AudioServerPlugInDriverRef driver;
static pid_t testChild;
static volatile sig_atomic_t publisherStop;
static void stop_publisher(int sig) { publisherStop = 1; }
static void cleanup_child(void) { if (testChild > 0) { kill(testChild, SIGKILL); waitpid(testChild, NULL, 0); } }
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
static _Atomic unsigned pluginChanges, boxChanges, aliveChanges, hiddenChanges;
static OSStatus changed(AudioServerPlugInHostRef h, AudioObjectID object, UInt32 count, const AudioObjectPropertyAddress *addresses) {
    for (UInt32 i = 0; i < count; i++) {
        if (object == 1 && addresses[i].mSelector == kAudioPlugInPropertyDeviceList) atomic_fetch_add(&pluginChanges, 1);
        if (object == 2 && addresses[i].mSelector == kAudioBoxPropertyDeviceList) atomic_fetch_add(&boxChanges, 1);
        if (object == 3 && addresses[i].mSelector == kAudioDevicePropertyDeviceIsAlive) atomic_fetch_add(&aliveChanges, 1);
        if (object == 3 && addresses[i].mSelector == kAudioDevicePropertyIsHidden) atomic_fetch_add(&hiddenChanges, 1);
    }
    // Reentrant host property read must not deadlock.
    AudioObjectID ids[4]; get(1, kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, ids, sizeof(ids));
    return noErr;
}
static OSStatus storage(AudioServerPlugInHostRef h, CFStringRef key, CFPropertyListRef *value) { *value = NULL; return noErr; }
static AudioServerPlugInHostInterface mockHost = { .PropertiesChanged = changed, .CopyFromStorage = storage };
static void wait_devices(unsigned count) {
    for (unsigned i = 0; i < 100; i++) {
        AudioObjectID ids[8]; UInt32 used = get(1, kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, ids, sizeof(ids));
        if (used == count * sizeof(AudioObjectID)) {
            CHECK(!count || ids[0] == 3);
            AudioObjectPropertyAddress a = address(kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal);
            UInt32 size; CHECK((*driver)->GetPropertyDataSize(driver, 1, 0, &a, 0, NULL, &size) == noErr && size == used);
            CHECK(get(2, kAudioBoxPropertyDeviceList, kAudioObjectPropertyScopeGlobal, ids, sizeof(ids)) == used);
            CHECK(get(1, kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal, ids, sizeof(ids)) == (count + 1) * sizeof(AudioObjectID));
            CHECK(ids[0] == 2 && (!count || ids[1] == 3));
            UInt32 alive, hidden;
            get(3, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, &alive, sizeof(alive));
            get(3, kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal, &hidden, sizeof(hidden));
            CHECK(alive == count && hidden == !count);
            CFStringRef uid = CFSTR("DualScreenAudio_UID"); AudioObjectID translated = 99; UInt32 returned;
            a = address(kAudioPlugInPropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal);
            CHECK((*driver)->GetPropertyData(driver, 1, 0, &a, sizeof(uid), &uid, sizeof(translated), &returned, &translated) == noErr);
            CHECK(translated == (count ? 3 : kAudioObjectUnknown));
            return;
        }
        usleep(25000);
    }
    CHECK(!"timed out waiting for device topology");
}
static uint64_t start_time(pid_t pid) {
    struct proc_bsdinfo info = {0}; CHECK(proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) == sizeof(info));
    return info.pbi_start_tvsec * 1000000ULL + info.pbi_start_tvusec;
}
static void presence_test(const char *self, const char *name) {
    CHECK(strncmp(name, "com.oleg.dualscreen.test.", 23) == 0); // never publish production state
    int pidToken, timeToken; char companion[256]; snprintf(companion, sizeof(companion), "%s.start-time", name);
    CHECK(notify_register_check(name, &pidToken) == NOTIFY_STATUS_OK);
    CHECK(notify_register_check(companion, &timeToken) == NOTIFY_STATUS_OK);
    CHECK(notify_set_state(pidToken, 0) == NOTIFY_STATUS_OK);
    CHECK((*driver)->Initialize(driver, &mockHost) == noErr);
    wait_devices(0);
    pid_t child = fork(); CHECK(child >= 0);
    if (!child) {
        const char *publisher = getenv("DUALSCREEN_PRESENCE_PUBLISHER");
        if (!publisher) publisher = self;
        execl(publisher, publisher, "--publisher", name, NULL); _exit(127);
    }
    testChild = child; atexit(cleanup_child);
    wait_devices(1);
    if (access("/usr/bin/sandbox-exec", X_OK) == 0) {
        pid_t observer = fork(); CHECK(observer >= 0);
        if (!observer) {
            char pid[32]; snprintf(pid, sizeof(pid), "%d", child);
            execl("/usr/bin/sandbox-exec", "sandbox-exec", "-p",
                "(version 1)(allow default)(deny process-info*)", self, "--restricted", name, pid, NULL);
            _exit(127);
        }
        int status; CHECK(waitpid(observer, &status, 0) == observer);
        CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    } else puts("SKIP sandbox observer: sandbox-exec unavailable");
    CHECK(kill(child, SIGSTOP) == 0); CHECK(waitpid(child, NULL, WUNTRACED) == child);
    int heartbeat; snprintf(companion, sizeof(companion), "%s.heartbeat", name);
    CHECK(notify_register_check(companion, &heartbeat) == NOTIFY_STATUS_OK);
    CHECK(notify_set_state(heartbeat, 0) == NOTIFY_STATUS_OK);
    wait_devices(0); // a live PID/birth is NOT an availability gate
    puts("PASS zero heartbeat hides even a live host PID");
    CHECK(notify_set_state(heartbeat, UINT64_MAX) == NOTIFY_STATUS_OK);
    usleep(600000); wait_devices(0);
    mach_timebase_info_data_t timebase; CHECK(mach_timebase_info(&timebase) == KERN_SUCCESS);
    printf("PASS clock timebase numer=%u denom=%u (raw ticks converted, not assumed nanoseconds)\n", timebase.numer, timebase.denom);
    uint64_t tenSeconds = 10000000000ULL * timebase.denom / timebase.numer;
    CHECK(notify_set_state(heartbeat, mach_continuous_time() + tenSeconds) == NOTIFY_STATUS_OK);
    usleep(600000); wait_devices(0); // future/previous-boot uptime cannot revive device
    CHECK(notify_set_state(heartbeat, 1) == NOTIFY_STATUS_OK);
    usleep(600000); wait_devices(0);
    CHECK(notify_set_state(heartbeat, mach_continuous_time()) == NOTIFY_STATUS_OK);
    wait_devices(1);
    wait_devices(0); // frozen publisher expires without process death
    puts("PASS future/overflow/reboot-like and stale tokens rejected; frozen live host expires");
    CHECK(kill(child, SIGCONT) == 0);
    wait_devices(1);
    CHECK(kill(child, SIGKILL) == 0); CHECK(waitpid(child, NULL, 0) == child); testChild = 0;
    wait_devices(0); // deliberately leave stale nonzero notify state
    puts("PASS crash heartbeat expires without stop/post");
    child = fork(); CHECK(child >= 0);
    if (!child) {
        const char *publisher = getenv("DUALSCREEN_PRESENCE_PUBLISHER");
        if (!publisher) publisher = self;
        execl(publisher, publisher, "--publisher", name, NULL); _exit(127);
    }
    testChild = child;
    wait_devices(1);
    CHECK(kill(child, SIGTERM) == 0);
    int status; CHECK(waitpid(child, &status, 0) == child);
    CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0); testChild = 0;
    uint64_t stopped = 99; CHECK(notify_get_state(heartbeat, &stopped) == NOTIFY_STATUS_OK && !stopped);
    wait_devices(0);
    puts("PASS actual publisher graceful stop clears heartbeat and removes device");
    notify_cancel(heartbeat);
    CHECK(atomic_load(&pluginChanges) >= 4 && atomic_load(&boxChanges) >= 4);
    CHECK(atomic_load(&aliveChanges) >= 4 && atomic_load(&hiddenChanges) >= 4);
    CHECK(notify_set_state(pidToken, 0) == NOTIFY_STATUS_OK);
    notify_cancel(pidToken); notify_cancel(timeToken);
    puts("PASS mock HAL host receives topology/alive/hidden changes; reentrant read does not deadlock");
}
int main(int argc, char **argv) {
    if (argc == 3 && !strcmp(argv[1], "--publisher")) {
        int t, birth; char companion[256]; snprintf(companion, sizeof(companion), "%s.start-time", argv[2]);
        CHECK(notify_register_check(argv[2], &t) == NOTIFY_STATUS_OK);
        CHECK(notify_register_check(companion, &birth) == NOTIFY_STATUS_OK);
        CHECK(notify_set_state(birth, start_time(getpid())) == NOTIFY_STATUS_OK);
        CHECK(notify_set_state(t, (uint64_t)getpid()) == NOTIFY_STATUS_OK); CHECK(notify_post(argv[2]) == NOTIFY_STATUS_OK);
        int heartbeat; snprintf(companion, sizeof(companion), "%s.heartbeat", argv[2]);
        CHECK(notify_register_check(companion, &heartbeat) == NOTIFY_STATUS_OK);
        signal(SIGTERM, stop_publisher);
        while (!publisherStop) { CHECK(notify_set_state(heartbeat, mach_continuous_time()) == NOTIFY_STATUS_OK); usleep(250000); }
        CHECK(notify_set_state(heartbeat, 0) == NOTIFY_STATUS_OK);
        CHECK(notify_set_state(t, 0) == NOTIFY_STATUS_OK);
        return 0;
    }
    bool restricted = argc == 4 && !strcmp(argv[1], "--restricted");
    CHECK(argc == 2 || argc == 3 || restricted);
    const char *bundlePath = restricted ? getenv("DUALSCREEN_TEST_BUNDLE") : argv[1];
    CHECK(bundlePath); void *bundle = dlopen(bundlePath, RTLD_NOW | RTLD_LOCAL);
    if (!bundle) { fprintf(stderr, "%s\n", dlerror()); return 1; }
    void *(*create)(CFAllocatorRef, CFUUIDRef) = dlsym(bundle, "BlackHole_Create");
    CHECK(create); driver = create(NULL, kAudioServerPlugInTypeUUID); CHECK(driver);
    if (restricted) {
        pid_t publisher = (pid_t)strtol(argv[3], NULL, 10);
        struct proc_bsdinfo info = {0};
        CHECK(proc_pidinfo(publisher, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info));
        puts("PASS sandbox denies live publisher proc_pidinfo: legacy availability gate fails");
        CHECK((*driver)->Initialize(driver, &mockHost) == noErr);
        wait_devices(1);
        puts("PASS restricted child detects separate publisher via actual HAL ABI without process-info permission");
        return 0;
    }
    CHECK(setenv("DUALSCREEN_TEST_BUNDLE", argv[1], 1) == 0);
    AudioObjectID devices[8];
    CHECK(get(kAudioObjectPlugInObject, kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, devices, sizeof(devices)) == 0);
    puts("PASS offline plug-in enumerates zero devices");
    string_property(3, kAudioObjectPropertyName, "Xiaoxin Pad Pro 12.7");
    string_property(3, kAudioDevicePropertyDeviceUID, "DualScreenAudio_UID");
    Float64 rate = 0; get(3, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, &rate, sizeof(rate)); CHECK(rate == 48000);
    AudioValueRange ranges[16]; UInt32 used = get(3, kAudioDevicePropertyAvailableNominalSampleRates, kAudioObjectPropertyScopeGlobal, ranges, sizeof(ranges));
    CHECK(used == sizeof(AudioValueRange) && ranges[0].mMinimum == 48000 && ranges[0].mMaximum == 48000);
    AudioStreamBasicDescription format;
    get(7, kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, &format, sizeof(format));
    CHECK(format.mSampleRate == 48000 && format.mChannelsPerFrame == 2);
    puts("PASS stereo; nominal and only supported sample rate = 48000 Hz");
    UInt32 hidden; get(3, kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal, &hidden, sizeof(hidden)); CHECK(hidden);
    get(12, kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal, &hidden, sizeof(hidden)); CHECK(hidden);
    AudioObjectID streams[8]; used = get(12, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeGlobal, streams, sizeof(streams)); CHECK(used == 0);
    puts("PASS offline primary hidden; secondary hidden with no streams");
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
    if (argc == 3) presence_test(argv[0], argv[2]);
    return 0;
}
