// getattrlistbulk buffer decoding. This is the only code in CSystemBridge: walking a packed,
// variable-length attribute buffer is far clearer in C than with Swift raw pointers.
// See getattrlistbulk(2) for the layout rules followed below.

#include "CSystemBridge.h"
#include <sys/attr.h>
#include <sys/vnode.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>

#define MH_BULK_BUFFER (128 * 1024)

static inline void take(void *dst, const char **cursor, size_t n) {
    memcpy(dst, *cursor, n);
    *cursor += n;
}

int mh_read_dir_entries(int dirfd, MHDirEntry *out, int capacity) {
    struct attrlist req = {0};
    req.bitmapcount = ATTR_BIT_MAP_COUNT;
    req.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE |
                     ATTR_CMN_MODTIME | ATTR_CMN_FLAGS | ATTR_CMN_FILEID | ATTR_CMN_ERROR;
    req.fileattr = ATTR_FILE_LINKCOUNT | ATTR_FILE_TOTALSIZE | ATTR_FILE_ALLOCSIZE;
    // With FSOPT_ATTR_CMN_EXTENDED, forkattr carries ATTR_CMNEXT_* bits.
    req.forkattr = ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_CLONE_REFCNT;

    // Without FSOPT_PACK_INVAL_ATTRS only valid attributes are packed, and the returned set says
    // which, so every field below is gated on it. Smallest possible entry is over 64 bytes, so the buffer never holds more than
    // capacity entries when capacity ≥ MH_BULK_BUFFER / 64.
    static _Thread_local char buffer[MH_BULK_BUFFER];
    size_t bufsize = MH_BULK_BUFFER;
    if ((size_t)capacity < MH_BULK_BUFFER / 64) bufsize = (size_t)capacity * 64;

    int count = getattrlistbulk(dirfd, &req, buffer, bufsize,
                                FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED);
    if (count <= 0) return count;

    const char *entry = buffer;
    int written = 0;
    for (int i = 0; i < count && written < capacity; i++) {
        uint32_t length;
        memcpy(&length, entry, sizeof(length));
        const char *cur = entry + sizeof(uint32_t);

        MHDirEntry *e = &out[written];
        memset(e, 0, sizeof(*e));

        attribute_set_t returned;
        take(&returned, &cur, sizeof(returned));

        // ATTR_CMN_ERROR comes right after the returned-attributes set.
        if (returned.commonattr & ATTR_CMN_ERROR) take(&e->error, &cur, sizeof(uint32_t));

        if (returned.commonattr & ATTR_CMN_NAME) {
            const char *refStart = cur;
            attrreference_t ref;
            take(&ref, &cur, sizeof(ref));
            const char *name = refStart + ref.attr_dataoffset;
            size_t n = ref.attr_length > 0 ? ref.attr_length - 1 : 0; // includes NUL
            if (n >= sizeof(e->name)) n = sizeof(e->name) - 1;
            memcpy(e->name, name, n);
            e->name[n] = 0;
        }
        if (returned.commonattr & ATTR_CMN_DEVID) take(&e->devID, &cur, sizeof(dev_t));
        if (returned.commonattr & ATTR_CMN_OBJTYPE) take(&e->objType, &cur, sizeof(fsobj_type_t));
        if (returned.commonattr & ATTR_CMN_MODTIME) {
            struct timespec ts;
            take(&ts, &cur, sizeof(ts));
            e->modTime = ts.tv_sec;
        }
        if (returned.commonattr & ATTR_CMN_FLAGS) take(&e->flags, &cur, sizeof(uint32_t));
        if (returned.commonattr & ATTR_CMN_FILEID) take(&e->fileID, &cur, sizeof(uint64_t));

        if (returned.fileattr & ATTR_FILE_LINKCOUNT) { take(&e->linkCount, &cur, sizeof(uint32_t)); e->hasFileAttrs = 1; }
        if (returned.fileattr & ATTR_FILE_TOTALSIZE) { off_t v; take(&v, &cur, sizeof(v)); e->logicalSize = (uint64_t)v; }
        if (returned.fileattr & ATTR_FILE_ALLOCSIZE) { off_t v; take(&v, &cur, sizeof(v)); e->allocSize = (uint64_t)v; }

        if (returned.forkattr & ATTR_CMNEXT_PRIVATESIZE) { off_t v; take(&v, &cur, sizeof(v)); e->privateSize = (uint64_t)v; }
        if (returned.forkattr & ATTR_CMNEXT_CLONEID) take(&e->cloneID, &cur, sizeof(uint64_t));
        if (returned.forkattr & ATTR_CMNEXT_CLONE_REFCNT) take(&e->cloneRefCount, &cur, sizeof(uint32_t));

        // Skip "." / ".." should they ever appear.
        if (!(e->name[0] == '.' && (e->name[1] == 0 || (e->name[1] == '.' && e->name[2] == 0)))) written++;
        entry += length;
    }
    return written;
}
