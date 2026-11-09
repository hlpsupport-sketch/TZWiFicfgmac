#include "cscsi.h"
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/scsi/SCSITaskLib.h>

struct TzDev {
    io_service_t service;
    IOCFPlugInInterface **plugin;
    SCSITaskDeviceInterface **dev;
    int exclusive;
    char disk[64];   /* whole-disk BSD name, e.g. "disk4", or "" */
};

static void set_err(char *e, size_t n, const char *fmt, ...) {
    if (!e || !n) return;
    va_list ap; va_start(ap, fmt); vsnprintf(e, n, fmt, ap); va_end(ap);
}

static int string_prop(io_service_t s, const char *key, IOOptionBits opts, char *out, size_t n) {
    CFStringRef k = CFStringCreateWithCString(kCFAllocatorDefault, key, kCFStringEncodingUTF8);
    CFTypeRef v = IORegistryEntrySearchCFProperty(s, kIOServicePlane, k, kCFAllocatorDefault, opts);
    CFRelease(k);
    if (!v) return 0;
    int ok = 0;
    if (CFGetTypeID(v) == CFStringGetTypeID())
        ok = CFStringGetCString((CFStringRef)v, out, (CFIndex)n, kCFStringEncodingUTF8);
    CFRelease(v);
    if (ok) { size_t l = strlen(out); while (l && (out[l-1] == ' ' || out[l-1] == 0)) out[--l] = 0; }
    return ok;
}

int tz_open(const char *vendor, const char *product, TzDev **out, char *err, size_t errlen) {
    *out = NULL;
    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(0, IOServiceMatching("IOSCSIPeripheralDeviceNub"), &it) != KERN_SUCCESS) {
        set_err(err, errlen, "Could not query macOS for SCSI devices.");
        return 1;
    }
    io_service_t svc, found = 0;
    int others = 0;
    while ((svc = IOIteratorNext(it))) {
        char v[128] = "", p[128] = "";
        string_prop(svc, "Vendor Identification", kIORegistryIterateRecursively | kIORegistryIterateParents, v, sizeof v);
        string_prop(svc, "Product Identification", kIORegistryIterateRecursively | kIORegistryIterateParents, p, sizeof p);
        if (strcmp(v, vendor) == 0 && strcmp(p, product) == 0) { found = svc; break; }
        others++;
        IOObjectRelease(svc);
    }
    IOObjectRelease(it);
    if (!found) {
        set_err(err, errlen, "No Tzone logger found. Plug it in with the USB cable and try again.");
        return 2;
    }

    TzDev *d = calloc(1, sizeof *d);
    d->service = found;

    /* Whole-disk BSD name (child IOMedia) so we can unmount it. */
    char bsd[64] = "";
    if (string_prop(found, "BSD Name", kIORegistryIterateRecursively, bsd, sizeof bsd) && strncmp(bsd, "disk", 4) == 0) {
        size_t i = 4; while (isdigit((unsigned char)bsd[i])) i++;
        bsd[i] = 0;                      /* strip partition suffix "sN" */
        snprintf(d->disk, sizeof d->disk, "%s", bsd);
        char cmd[160];
        snprintf(cmd, sizeof cmd, "/usr/sbin/diskutil unmountDisk /dev/%s >/dev/null 2>&1", d->disk);
        (void)system(cmd);
    }

    SInt32 score = 0;
    IOReturn kr = IOCreatePlugInInterfaceForService(found, kIOSCSITaskDeviceUserClientTypeID,
                                                    kIOCFPlugInInterfaceID, &d->plugin, &score);
    if (kr != kIOReturnSuccess || !d->plugin) {
        set_err(err, errlen, "Could not open the logger (IOKit error 0x%x).", (unsigned)kr);
        tz_close(d);
        return 3;
    }
    HRESULT hr = (*d->plugin)->QueryInterface(d->plugin,
                    CFUUIDGetUUIDBytes(kIOSCSITaskDeviceInterfaceID), (LPVOID *)&d->dev);
    if (hr != S_OK || !d->dev) {
        set_err(err, errlen, "The logger does not expose a SCSI interface to apps.");
        tz_close(d);
        return 4;
    }
    kr = (*d->dev)->ObtainExclusiveAccess(d->dev);
    if (kr != kIOReturnSuccess) {
        set_err(err, errlen, "The logger is in use by macOS (error 0x%x). Eject its disk in Finder and try again.", (unsigned)kr);
        tz_close(d);
        return 5;
    }
    d->exclusive = 1;
    *out = d;
    return 0;
}

int tz_exec(TzDev *d, const uint8_t *cdb, uint8_t cdb_len, int dir,
            void *buf, uint32_t len, char *err, size_t errlen) {
    SCSITaskInterface **task = (*d->dev)->CreateSCSITask(d->dev);
    if (!task) { set_err(err, errlen, "Could not create SCSI task."); return 1; }
    int rc = 1;
    SCSICommandDescriptorBlock c;
    memset(c, 0, sizeof c);
    memcpy(c, cdb, cdb_len > sizeof c ? sizeof c : cdb_len);
    (*task)->SetCommandDescriptorBlock(task, c, cdb_len);
    SCSITaskSGElement sg = { .address = (uint64_t)(uintptr_t)buf, .length = len };
    if (dir == TZ_DIR_NONE || len == 0)
        (*task)->SetScatterGatherEntries(task, &sg, 0, 0, kSCSIDataTransfer_NoDataTransfer);
    else
        (*task)->SetScatterGatherEntries(task, &sg, 1, len,
            dir == TZ_DIR_IN ? kSCSIDataTransfer_FromTargetToInitiator : kSCSIDataTransfer_FromInitiatorToTarget);
    (*task)->SetTimeoutDuration(task, 10000);
    SCSI_Sense_Data sense; memset(&sense, 0, sizeof sense);
    SCSITaskStatus status = 0; UInt64 moved = 0;
    IOReturn kr = (*task)->ExecuteTaskSync(task, &sense, &status, &moved);
    if (kr != kIOReturnSuccess) set_err(err, errlen, "USB transfer failed (error 0x%x).", (unsigned)kr);
    else if (status != kSCSITaskStatus_GOOD) set_err(err, errlen, "The logger rejected the command (SCSI status 0x%x).", (unsigned)status);
    else rc = 0;
    (*task)->Release(task);
    return rc;
}

void tz_close(TzDev *d) {
    if (!d) return;
    if (d->dev) {
        if (d->exclusive) (*d->dev)->ReleaseExclusiveAccess(d->dev);
        (*d->dev)->Release(d->dev);
    }
    if (d->plugin) IODestroyPlugInInterface(d->plugin);
    if (d->service) IOObjectRelease(d->service);
    if (d->disk[0]) {
        char cmd[160];
        snprintf(cmd, sizeof cmd, "/usr/sbin/diskutil mountDisk /dev/%s >/dev/null 2>&1 &", d->disk);
        (void)system(cmd);
    }
    free(d);
}
