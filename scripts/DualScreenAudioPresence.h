/* DualScreen modifications to BlackHole; GPL-3.0, see upstream/LICENSE.
 * Included after upstream globals. No work here executes on the audio IO thread.
 */
#include <stdatomic.h>
#include <notify.h>
#include <mach/mach_time.h>
#ifndef DS_AUDIO_PRESENCE_NOTIFY_NAME
#define DS_AUDIO_PRESENCE_NOTIFY_NAME "com.oleg.dualscreen.host.audio-pid"
#endif
static _Atomic bool dsPresent = false;
static int dsHeartbeatToken = NOTIFY_TOKEN_INVALID;
static dispatch_source_t dsTimer;
static bool dsHostAlive(void) {
    // Public notify state + our own monotonic clock only: no cross-UID process
    // inspection, signals, filesystem IO or dependence on coreaudiod privileges.
    if (dsHeartbeatToken == NOTIFY_TOKEN_INVALID && notify_register_check(DS_AUDIO_PRESENCE_NOTIFY_NAME ".heartbeat", &dsHeartbeatToken) != NOTIFY_STATUS_OK) return false;
    uint64_t heartbeat = 0;
    if (notify_get_state(dsHeartbeatToken, &heartbeat) != NOTIFY_STATUS_OK || !heartbeat) return false;
    uint64_t now = mach_continuous_time();
    if (heartbeat > now) return false; // future / previous-boot uptime, no unsigned wrap
    mach_timebase_info_data_t timebase;
    if (mach_timebase_info(&timebase) != KERN_SUCCESS || !timebase.numer || !timebase.denom) return false;
    // Swift publishes raw mach_continuous_time ticks, NOT nanoseconds. Widen
    // before multiplying: even deliberately malformed uint64 state cannot wrap.
    return (__uint128_t)(now - heartbeat) * timebase.numer <= (__uint128_t)1500000000ULL * timebase.denom;
}
static void dsRefresh(bool notifyHost) {
    bool online = dsHostAlive();
    if (atomic_exchange(&dsPresent, online) == online || !notifyHost) return;
    const AudioObjectPropertyAddress plugin[] = {
        {kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
        {kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain}
    };
    const AudioObjectPropertyAddress box[] = {
        {kAudioBoxPropertyDeviceList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
        {kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain}
    };
    const AudioObjectPropertyAddress device[] = {
        {kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
        {kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain}
    };
    // No state mutex is held across host callbacks. Removing the device from
    // the topology lets CoreAudio perform its own default-route fallback on crash.
    gPlugIn_Host->PropertiesChanged(gPlugIn_Host, kObjectID_Device, 2, device);
    gPlugIn_Host->PropertiesChanged(gPlugIn_Host, kObjectID_Box, 2, box);
    gPlugIn_Host->PropertiesChanged(gPlugIn_Host, kObjectID_PlugIn, 2, plugin);
}
static void dsInitializePresence(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dsRefresh(false);
        dispatch_queue_t queue = dispatch_queue_create("com.dualscreen.audio.presence", DISPATCH_QUEUE_SERIAL);
        dsTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
        dispatch_source_set_timer(dsTimer, dispatch_time(DISPATCH_TIME_NOW, 0), 250 * NSEC_PER_MSEC, 25 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(dsTimer, ^{ dsRefresh(true); });
        dispatch_resume(dsTimer);
        dispatch_release(queue);
    });
}

/* Return an authoritative list, including an empty list. The mirror is never
 * published, even when the primary is active. A box is kept for stable topology.
 */
static bool dsList(AudioObjectID object, AudioObjectPropertySelector selector,
                   AudioObjectID ids[2], UInt32 *count) {
    bool online = atomic_load(&dsPresent);
    *count = 0;
    if (object == kObjectID_PlugIn) {
        if (selector == kAudioObjectPropertyOwnedObjects) {
            ids[(*count)++] = kObjectID_Box;
            if (online) ids[(*count)++] = kObjectID_Device;
            return true;
        }
        if (selector == kAudioPlugInPropertyDeviceList) {
            if (online) ids[(*count)++] = kObjectID_Device;
            return true;
        }
    }
    if (object == kObjectID_Box && (selector == kAudioBoxPropertyDeviceList ||
                                    selector == kAudioObjectPropertyOwnedObjects)) {
        if (online) ids[(*count)++] = kObjectID_Device;
        return true;
    }
    return false;
}
