#ifndef MG_MULTITOUCH_BRIDGE_H
#define MG_MULTITOUCH_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

// Minimal, owned C interface over Apple's PRIVATE MultitouchSupport.framework.
//
// The framework is undocumented, unsupported, and not App Store compatible.
// All of its symbols are resolved at runtime with dlopen/dlsym so the host app
// can launch and report the backend as unavailable if a future macOS release
// removes or changes it. Swift code only ever sees the structs declared here.

#define MG_BRIDGE_OK 0
#define MG_BRIDGE_FRAMEWORK_UNAVAILABLE 1
#define MG_BRIDGE_SYMBOLS_MISSING 2
#define MG_BRIDGE_NO_DEVICES 3
#define MG_BRIDGE_ALREADY_RUNNING 4

#define MG_BRIDGE_MAX_DEVICES 8
#define MG_BRIDGE_MAX_CONTACTS 32

/// One contact, copied out of the framework's private struct into a layout we own.
typedef struct {
    int32_t identifier;  // stable while the finger stays on the surface
    int32_t state;       // raw MultitouchSupport touch state (4 == touching)
    float x;             // normalized 0...1, origin at the bottom-left
    float y;
    float velocityX;     // normalized units per second
    float velocityY;
    float size;          // contact area proxy, useful for palm rejection
    float density;
    float angle;
    float majorAxis;
    float minorAxis;
} MGContact;

typedef struct {
    uint64_t deviceID;      // MTDeviceGetDeviceID, 0 if unavailable
    bool isBuiltIn;
    int32_t surfaceWidth;   // hundredths of a millimetre, 0 if unknown
    int32_t surfaceHeight;
} MGDeviceInfo;

/// Invoked on a private MultitouchSupport thread. Calls are serialized by the
/// bridge, and none are in flight once MGBridgeStop() has returned.
typedef void (*MGFrameCallback)(const MGDeviceInfo *device,
                                const MGContact *contacts,
                                int32_t count,
                                double timestamp,
                                void *context);

/// Loads the framework and resolves symbols. Idempotent and thread-safe.
int32_t MGBridgeLoad(void);

/// Copies information about currently attached multitouch devices.
/// Returns the number of devices written, or -1 if the framework is unavailable.
int32_t MGBridgeCopyDevices(MGDeviceInfo *buffer, int32_t capacity);

/// Registers for frames from every attached multitouch device.
int32_t MGBridgeStart(MGFrameCallback callback, void *context);

/// Unregisters and stops all devices. Safe to call when not running.
/// Must not be called from inside the frame callback.
void MGBridgeStop(void);

bool MGBridgeIsRunning(void);

// Trackpad haptics (PRIVATE MTActuator API in the same framework).
// Built-in actuation IDs: 3 = weak, 4 = medium, 6 = strong.
#define MG_HAPTIC_WEAK 3
#define MG_HAPTIC_MEDIUM 4
#define MG_HAPTIC_STRONG 6

/// Plays one click on the trackpad's Taptic Engine. Opens the actuator of the
/// built-in (or first) Force Touch trackpad on first use. Thread-safe.
/// Returns MG_BRIDGE_OK, or an error if no actuator is available.
int32_t MGBridgeActuate(int32_t actuationID);

#endif
