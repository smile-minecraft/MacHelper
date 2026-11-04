#ifndef CSYSTEMBRIDGE_H
#define CSYSTEMBRIDGE_H

#include <stdint.h>
#include <mach/mach.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>

// MARK: - Mach helpers
// `mach_task_self_` is a mutable C global, which Swift 6 strict concurrency rejects.
static inline mach_port_t mh_task_self(void) { return mach_task_self(); }

// MARK: - SMC (AppleSMC user client)

enum {
    MH_SMC_KERNEL_INDEX = 2,
    MH_SMC_CMD_READ_BYTES = 5,
    MH_SMC_CMD_WRITE_BYTES = 6,
    MH_SMC_CMD_READ_INDEX = 8,
    MH_SMC_CMD_READ_KEYINFO = 9,
};

typedef struct {
    uint8_t major;
    uint8_t minor;
    uint8_t build;
    uint8_t reserved;
    uint16_t release;
} MHSMCVersion;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} MHSMCPLimitData;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t dataAttributes;
} MHSMCKeyInfo;

typedef struct {
    uint32_t key;
    MHSMCVersion vers;
    MHSMCPLimitData pLimitData;
    MHSMCKeyInfo keyInfo;
    uint8_t result;
    uint8_t status;
    uint8_t data8;
    uint32_t data32;
    uint8_t bytes[32];
} MHSMCKeyData;

_Static_assert(sizeof(MHSMCKeyData) == 80, "MHSMCKeyData must match the kernel's SMCKeyData_t layout");

// MARK: - IOHIDEventSystem (private; Apple Silicon temperature sensors)

typedef struct CF_BRIDGED_TYPE(id) __IOHIDEvent *IOHIDEventRef;
typedef struct CF_BRIDGED_TYPE(id) __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct CF_BRIDGED_TYPE(id) __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

enum {
    MH_HID_EVENT_TYPE_TEMPERATURE = 15,
    MH_HID_EVENT_FIELD_TEMPERATURE = (15 << 16),
    MH_HID_USAGE_PAGE_APPLE_VENDOR = 0xff00,
    MH_HID_USAGE_TEMPERATURE_SENSOR = 5,
};

IOHIDEventSystemClientRef _Nullable IOHIDEventSystemClientCreate(CFAllocatorRef _Nullable allocator) CF_RETURNS_RETAINED;
/// type: 0 admin, 1 monitor, 2 passive, 3 rate-controlled, 4 simple.
IOHIDEventSystemClientRef _Nullable IOHIDEventSystemClientCreateWithType(CFAllocatorRef _Nullable allocator, int32_t type, CFDictionaryRef _Nullable attributes) CF_RETURNS_RETAINED;
int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef _Nonnull client, CFDictionaryRef _Nonnull match);
CFArrayRef _Nullable IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef _Nonnull client) CF_RETURNS_RETAINED;
CFTypeRef _Nullable IOHIDServiceClientCopyProperty(IOHIDServiceClientRef _Nonnull service, CFStringRef _Nonnull key) CF_RETURNS_RETAINED;
IOHIDEventRef _Nullable IOHIDServiceClientCopyEvent(IOHIDServiceClientRef _Nonnull service, int64_t type, int32_t options, int64_t timestamp) CF_RETURNS_RETAINED;
double IOHIDEventGetFloatValue(IOHIDEventRef _Nonnull event, int32_t field);

// MARK: - IOReport (private; power / energy, GPU residency)

typedef struct IOReportSubscription *IOReportSubscriptionRef;

CFDictionaryRef _Nullable IOReportCopyChannelsInGroup(CFStringRef _Nullable group, CFStringRef _Nullable subgroup,
                                                      uint64_t a, uint64_t b, uint64_t c) CF_RETURNS_RETAINED;
void IOReportMergeChannels(CFDictionaryRef _Nonnull a, CFDictionaryRef _Nonnull b, CFTypeRef _Nullable unused);
IOReportSubscriptionRef _Nullable IOReportCreateSubscription(const void *_Nullable a,
                                                             CFMutableDictionaryRef _Nonnull desiredChannels,
                                                             CFMutableDictionaryRef _Nullable *_Nullable subscribedChannels,
                                                             uint64_t channelID, CFTypeRef _Nullable b);
CFDictionaryRef _Nullable IOReportCreateSamples(IOReportSubscriptionRef _Nonnull sub,
                                                CFMutableDictionaryRef _Nonnull subscribedChannels,
                                                CFTypeRef _Nullable a) CF_RETURNS_RETAINED;
CFDictionaryRef _Nullable IOReportCreateSamplesDelta(CFDictionaryRef _Nonnull prev, CFDictionaryRef _Nonnull current,
                                                     CFTypeRef _Nullable a) CF_RETURNS_RETAINED;
CFStringRef _Nullable IOReportChannelGetGroup(CFDictionaryRef _Nonnull channel) CF_RETURNS_NOT_RETAINED;
CFStringRef _Nullable IOReportChannelGetSubGroup(CFDictionaryRef _Nonnull channel) CF_RETURNS_NOT_RETAINED;
CFStringRef _Nullable IOReportChannelGetChannelName(CFDictionaryRef _Nonnull channel) CF_RETURNS_NOT_RETAINED;
CFStringRef _Nullable IOReportChannelGetUnitLabel(CFDictionaryRef _Nonnull channel) CF_RETURNS_NOT_RETAINED;
int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef _Nonnull channel, int32_t index);
int32_t IOReportStateGetCount(CFDictionaryRef _Nonnull channel);
CFStringRef _Nullable IOReportStateGetNameForIndex(CFDictionaryRef _Nonnull channel, int32_t index) CF_RETURNS_NOT_RETAINED;
int64_t IOReportStateGetResidency(CFDictionaryRef _Nonnull channel, int32_t index);

// MARK: - getattrlistbulk (fast directory enumeration)

/// One directory entry decoded from a getattrlistbulk buffer. Plain data, no ownership.
typedef struct {
    char name[256];
    int32_t error;          // per-entry errno (ATTR_CMN_ERROR), 0 if fine
    uint32_t objType;       // VREG=1, VDIR=2, VLNK=5 …
    int32_t devID;
    uint32_t flags;         // st_flags (UF_*/SF_*)
    int64_t modTime;        // seconds since 1970
    uint64_t fileID;        // inode
    uint32_t linkCount;     // files only
    uint64_t logicalSize;   // files only
    uint64_t allocSize;     // files only: allocated bytes
    uint64_t privateSize;   // bytes not shared with APFS clones (0 if unknown)
    uint64_t cloneID;       // APFS clone family id (0 if unknown)
    uint32_t cloneRefCount; // files sharing blocks with this one (0 if unknown)
    uint8_t hasFileAttrs;
} MHDirEntry;

/// Reads the next batch of entries from an open directory fd (O_RDONLY|O_DIRECTORY).
/// Returns the number of entries written to `out` (≤ capacity), 0 at end of directory,
/// or -1 with errno set. Call repeatedly until it returns 0.
int mh_read_dir_entries(int dirfd, MHDirEntry *_Nonnull out, int capacity);

#endif
