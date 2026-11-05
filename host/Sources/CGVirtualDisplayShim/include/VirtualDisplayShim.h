#ifndef VIRTUAL_DISPLAY_SHIM_H
#define VIRTUAL_DISPLAY_SHIM_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Modes are built as: (pixelW x pixelH) for every rate in `rates`,
// then (pixelW/2 x pixelH/2) for every rate (HiDPI "looks-like" ladder).
// The FIRST mode in the applied list becomes the display's active mode
// (WindowServer ignores programmatic mode switches on virtual displays),
// so pass rates sorted with the desired refresh first.
//
// Must be called from the main thread (CGVirtualDisplay requires it).
// Returns the new CGDirectDisplayID, or 0 on failure.
uint32_t vd_create_display(uint32_t pixelW, uint32_t pixelH,
                           const double *rates, size_t rateCount,
                           bool hiDPI,
                           uint32_t vendorID, uint32_t productID, uint32_t serial,
                           const char *name);

// Releases the retained CGVirtualDisplay, removing the display.
void vd_release_display(void);

#ifdef __cplusplus
}
#endif

#endif /* VIRTUAL_DISPLAY_SHIM_H */
