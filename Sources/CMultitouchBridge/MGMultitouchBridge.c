#include "MGMultitouchBridge.h"

#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <pthread.h>
#include <string.h>

// ---------------------------------------------------------------------------
// PRIVATE API DECLARATIONS
//
// These mirror the community reverse-engineered layout of MultitouchSupport's
// contact record. Field order and sizes are load-bearing. Verified on an M4
// MacBook Air (Mac16,12) running macOS 27.0 (26A428): 96-byte records,
// stable identifiers, state 4 while touching, positions within 0...1.
// A future macOS release can change any of this without notice.
// ---------------------------------------------------------------------------

typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint position; MTPoint velocity; } MTVector;

typedef struct {
    int32_t frame;
    double timestamp;
    int32_t identifier;
    int32_t state;
    int32_t fingerID;
    int32_t handID;
    MTVector normalized;
    float size;
    int32_t reserved1;
    float angle;
    float majorAxis;
    float minorAxis;
    MTVector millimeters;
    int32_t reserved2;
    int32_t reserved3;
    float density;
} MTContact;

_Static_assert(sizeof(MTContact) == 96, "MultitouchSupport contact layout changed");

typedef void *MTDeviceRef;
typedef int (*MTContactFrameCallback)(MTDeviceRef, MTContact *, int32_t, double, int32_t);

static const char *kFrameworkPath =
    "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport";

static struct {
    CFArrayRef (*createList)(void);
    void (*registerCallback)(MTDeviceRef, MTContactFrameCallback);
    void (*unregisterCallback)(MTDeviceRef, MTContactFrameCallback);
    void (*start)(MTDeviceRef, int32_t);
    void (*stop)(MTDeviceRef);
    // Optional: absence only degrades device metadata.
    bool (*isBuiltIn)(MTDeviceRef);
    int32_t (*getDeviceID)(MTDeviceRef, uint64_t *);
    int32_t (*getDimensions)(MTDeviceRef, int32_t *, int32_t *);
    // Optional haptics.
    CFTypeRef (*actuatorCreate)(uint64_t);
    int32_t (*actuatorOpen)(CFTypeRef);
    int32_t (*actuatorActuate)(CFTypeRef, int32_t, uint32_t, float, float);
} mt;

static pthread_once_t load_once = PTHREAD_ONCE_INIT;
static int32_t load_status = MG_BRIDGE_FRAMEWORK_UNAVAILABLE;

// Guards start/stop transitions.
static pthread_mutex_t lifecycle_lock = PTHREAD_MUTEX_INITIALIZER;
// Held while a frame is delivered; guarantees no delivery is in flight after stop.
static pthread_mutex_t delivery_lock = PTHREAD_MUTEX_INITIALIZER;

static CFArrayRef device_list = NULL;
static MTDeviceRef devices[MG_BRIDGE_MAX_DEVICES];
static MGDeviceInfo device_info[MG_BRIDGE_MAX_DEVICES];
static int32_t device_count = 0;
static MGFrameCallback client_callback = NULL;
static void *client_context = NULL;
static bool running = false;

static void load_framework(void) {
    void *handle = dlopen(kFrameworkPath, RTLD_LAZY | RTLD_LOCAL);
    if (handle == NULL) {
        load_status = MG_BRIDGE_FRAMEWORK_UNAVAILABLE;
        return;
    }
    mt.createList = dlsym(handle, "MTDeviceCreateList");
    mt.registerCallback = dlsym(handle, "MTRegisterContactFrameCallback");
    mt.unregisterCallback = dlsym(handle, "MTUnregisterContactFrameCallback");
    mt.start = dlsym(handle, "MTDeviceStart");
    mt.stop = dlsym(handle, "MTDeviceStop");
    mt.isBuiltIn = dlsym(handle, "MTDeviceIsBuiltIn");
    mt.getDeviceID = dlsym(handle, "MTDeviceGetDeviceID");
    mt.getDimensions = dlsym(handle, "MTDeviceGetSensorSurfaceDimensions");
    mt.actuatorCreate = dlsym(handle, "MTActuatorCreateFromDeviceID");
    mt.actuatorOpen = dlsym(handle, "MTActuatorOpen");
    mt.actuatorActuate = dlsym(handle, "MTActuatorActuate");

    bool required = mt.createList && mt.registerCallback && mt.unregisterCallback && mt.start && mt.stop;
    load_status = required ? MG_BRIDGE_OK : MG_BRIDGE_SYMBOLS_MISSING;
}

int32_t MGBridgeLoad(void) {
    pthread_once(&load_once, load_framework);
    return load_status;
}

static MGDeviceInfo describe_device(MTDeviceRef device) {
    MGDeviceInfo info;
    memset(&info, 0, sizeof(info));
    if (mt.getDeviceID != NULL) {
        uint64_t identifier = 0;
        if (mt.getDeviceID(device, &identifier) == 0) {
            info.deviceID = identifier;
        }
    }
    if (mt.isBuiltIn != NULL) {
        info.isBuiltIn = mt.isBuiltIn(device);
    }
    if (mt.getDimensions != NULL) {
        int32_t width = 0, height = 0;
        mt.getDimensions(device, &width, &height);
        if (width > 0 && height > 0) {
            info.surfaceWidth = width;
            info.surfaceHeight = height;
        }
    }
    return info;
}

int32_t MGBridgeCopyDevices(MGDeviceInfo *buffer, int32_t capacity) {
    if (MGBridgeLoad() != MG_BRIDGE_OK) {
        return -1;
    }
    CFArrayRef list = mt.createList();
    if (list == NULL) {
        return 0;
    }
    CFIndex count = CFArrayGetCount(list);
    int32_t written = 0;
    for (CFIndex index = 0; index < count && written < capacity; index++) {
        MTDeviceRef device = (MTDeviceRef)CFArrayGetValueAtIndex(list, index);
        buffer[written++] = describe_device(device);
    }
    CFRelease(list);
    return written;
}

static int frame_callback(MTDeviceRef device, MTContact *touches, int32_t count, double timestamp, int32_t frame) {
    (void)frame;
    if (count < 0 || (count > 0 && touches == NULL)) {
        return 0;
    }
    if (count > MG_BRIDGE_MAX_CONTACTS) {
        count = MG_BRIDGE_MAX_CONTACTS;
    }

    MGContact contacts[MG_BRIDGE_MAX_CONTACTS];
    for (int32_t index = 0; index < count; index++) {
        const MTContact *source = &touches[index];
        contacts[index] = (MGContact){
            .identifier = source->identifier,
            .state = source->state,
            .x = source->normalized.position.x,
            .y = source->normalized.position.y,
            .velocityX = source->normalized.velocity.x,
            .velocityY = source->normalized.velocity.y,
            .size = source->size,
            .density = source->density,
            .angle = source->angle,
            .majorAxis = source->majorAxis,
            .minorAxis = source->minorAxis,
        };
    }

    pthread_mutex_lock(&delivery_lock);
    if (client_callback != NULL) {
        const MGDeviceInfo *info = NULL;
        for (int32_t index = 0; index < device_count; index++) {
            if (devices[index] == device) {
                info = &device_info[index];
                break;
            }
        }
        if (info != NULL) {
            client_callback(info, contacts, count, timestamp, client_context);
        }
    }
    pthread_mutex_unlock(&delivery_lock);
    return 0;
}

int32_t MGBridgeStart(MGFrameCallback callback, void *context) {
    int32_t status = MGBridgeLoad();
    if (status != MG_BRIDGE_OK) {
        return status;
    }

    pthread_mutex_lock(&lifecycle_lock);
    if (running) {
        pthread_mutex_unlock(&lifecycle_lock);
        return MG_BRIDGE_ALREADY_RUNNING;
    }

    CFArrayRef list = mt.createList();
    CFIndex available = list != NULL ? CFArrayGetCount(list) : 0;
    if (available == 0) {
        if (list != NULL) {
            CFRelease(list);
        }
        pthread_mutex_unlock(&lifecycle_lock);
        return MG_BRIDGE_NO_DEVICES;
    }

    pthread_mutex_lock(&delivery_lock);
    device_list = list;
    device_count = 0;
    for (CFIndex index = 0; index < available && device_count < MG_BRIDGE_MAX_DEVICES; index++) {
        MTDeviceRef device = (MTDeviceRef)CFArrayGetValueAtIndex(list, index);
        devices[device_count] = device;
        device_info[device_count] = describe_device(device);
        device_count++;
    }
    client_callback = callback;
    client_context = context;
    pthread_mutex_unlock(&delivery_lock);

    for (int32_t index = 0; index < device_count; index++) {
        mt.registerCallback(devices[index], frame_callback);
        mt.start(devices[index], 0);
    }
    running = true;
    pthread_mutex_unlock(&lifecycle_lock);
    return MG_BRIDGE_OK;
}

void MGBridgeStop(void) {
    pthread_mutex_lock(&lifecycle_lock);
    if (!running) {
        pthread_mutex_unlock(&lifecycle_lock);
        return;
    }
    // Stop the hardware without holding delivery_lock: MTDeviceStop may wait
    // for an in-flight callback, which itself waits on delivery_lock.
    for (int32_t index = 0; index < device_count; index++) {
        mt.unregisterCallback(devices[index], frame_callback);
        mt.stop(devices[index]);
    }

    pthread_mutex_lock(&delivery_lock);
    client_callback = NULL;
    client_context = NULL;
    device_count = 0;
    CFArrayRef list = device_list;
    device_list = NULL;
    pthread_mutex_unlock(&delivery_lock);

    if (list != NULL) {
        CFRelease(list);
    }
    running = false;
    pthread_mutex_unlock(&lifecycle_lock);
}

static pthread_mutex_t haptic_lock = PTHREAD_MUTEX_INITIALIZER;
static CFTypeRef actuator = NULL;
static bool actuator_failed = false;

/// Opens an actuator for the built-in trackpad, else the first that opens.
static CFTypeRef open_actuator(void) {
    if (!mt.actuatorCreate || !mt.actuatorOpen || !mt.getDeviceID) {
        return NULL;
    }
    CFArrayRef list = mt.createList();
    if (list == NULL) {
        return NULL;
    }
    CFTypeRef result = NULL;
    CFIndex count = CFArrayGetCount(list);
    for (int pass = 0; pass < 2 && result == NULL; pass++) {
        for (CFIndex index = 0; index < count && result == NULL; index++) {
            MTDeviceRef device = (MTDeviceRef)CFArrayGetValueAtIndex(list, index);
            bool builtIn = mt.isBuiltIn != NULL && mt.isBuiltIn(device);
            if (pass == 0 && !builtIn) {
                continue;
            }
            uint64_t identifier = 0;
            if (mt.getDeviceID(device, &identifier) != 0 || identifier == 0) {
                continue;
            }
            CFTypeRef candidate = mt.actuatorCreate(identifier);
            if (candidate == NULL) {
                continue;
            }
            if (mt.actuatorOpen(candidate) == 0) {
                result = candidate;
            } else {
                CFRelease(candidate);
            }
        }
    }
    CFRelease(list);
    return result;
}

int32_t MGBridgeActuate(int32_t actuationID) {
    int32_t status = MGBridgeLoad();
    if (status != MG_BRIDGE_OK) {
        return status;
    }
    if (mt.actuatorActuate == NULL) {
        return MG_BRIDGE_SYMBOLS_MISSING;
    }
    pthread_mutex_lock(&haptic_lock);
    if (actuator == NULL && !actuator_failed) {
        actuator = open_actuator();
        actuator_failed = actuator == NULL;
    }
    int32_t result = MG_BRIDGE_NO_DEVICES;
    if (actuator != NULL) {
        result = mt.actuatorActuate(actuator, actuationID, 0, 0.0f, 0.0f) == 0 ? MG_BRIDGE_OK : MG_BRIDGE_NO_DEVICES;
        if (result != MG_BRIDGE_OK) {
            // The device may have gone away (sleep, disconnect); reopen next time.
            CFRelease(actuator);
            actuator = NULL;
        }
    }
    pthread_mutex_unlock(&haptic_lock);
    return result;
}

bool MGBridgeIsRunning(void) {
    pthread_mutex_lock(&lifecycle_lock);
    bool result = running;
    pthread_mutex_unlock(&lifecycle_lock);
    return result;
}
