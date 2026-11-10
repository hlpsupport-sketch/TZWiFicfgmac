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

#define MAX_CAND 24

static void collect(io_iterator_t it, io_service_t *cand, int *n) {
    io_service_t s;
    while ((s = IOIteratorNext(it))) {
        if (*n < MAX_CAND) cand[(*n)++] = s; else IOObjectRelease(s);
    }
}

static int is_logger(io_service_t s, const char *vendor, const char *product) {
    char v[128] = "", p[128] = "";
    IOOptionBits up = kIORegistryIterateRecursively | kIORegistryIterateParents;
    string_prop(s, "Vendor Identification", up, v, sizeof v);
    string_prop(s, "Product Identification", up, p, sizeof p);
    return strcmp(v, vendor) == 0 && strcmp(p, product) == 0;
}

int tz_open(const char *vendor, const char *product, TzDev **out, char *err, size_t errlen) {
    *out = NULL;
    io_service_t cand[MAX_CAND]; int n = 0;
    io_iterator_t it = 0;

    /* A) Services that publish the SCSI task user-client category (Apple's documented route). */
    CFMutableDictionaryRef mA = IOServiceMatching("IOService");
    CFMutableDictionaryRef pm = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(pm, CFSTR("SCSITaskDeviceCategory"), CFSTR("SCSITaskUserClientDevice"));
    CFDictionarySetValue(mA, CFSTR(kIOPropertyMatchKey), pm);
    CFRelease(pm);
    if (IOServiceGetMatchingServices(0, mA, &it) == KERN_SUCCESS) { collect(it, cand, &n); IOObjectRelease(it); }

    /* B) The peripheral-device nubs themselves (what version 1 tried). */
    if (IOServiceGetMatchingServices(0, IOServiceMatching("IOSCSIPeripheralDeviceNub"), &it) == KERN_SUCCESS) {
        collect(it, cand, &n); IOObjectRelease(it);
    }

    /* Keep only entries that belong to the logger. */
    io_service_t mine[MAX_CAND]; int m = 0;
    for (int i = 0; i < n; i++) {
        if (is_logger(cand[i], vendor, product)) mine[m++] = cand[i]; else IOObjectRelease(cand[i]);
    }
    if (m == 0) {
        set_err(err, errlen, "No Tzone logger found. Plug it in with the USB cable and try again.");
        return 2;
    }

    TzDev *d = calloc(1, sizeof *d);

    /* Whole-disk BSD name (child IOMedia) so we can unmount it first. */
    for (int i = 0; i < m && !d->disk[0]; i++) {
        char bsd[64] = "";
        if (string_prop(mine[i], "BSD Name", kIORegistryIterateRecursively, bsd, sizeof bsd) && strncmp(bsd, "disk", 4) == 0) {
            size_t k = 4; while (isdigit((unsigned char)bsd[k])) k++;
            bsd[k] = 0;
            snprintf(d->disk, sizeof d->disk, "%s", bsd);
        }
    }
    if (d->disk[0]) {
        char cmd[160];
        snprintf(cmd, sizeof cmd, "/usr/sbin/diskutil unmountDisk /dev/%s >/dev/null 2>&1", d->disk);
        (void)system(cmd);
    }

    IOReturn lastkr = kIOReturnUnsupported; const char *stage = "plug-in";
    for (int i = 0; i < m; i++) {
        IOCFPlugInInterface **plugin = NULL; SInt32 score = 0;
        IOReturn kr = IOCreatePlugInInterfaceForService(mine[i], kIOSCSITaskDeviceUserClientTypeID,
                                                        kIOCFPlugInInterfaceID, &plugin, &score);
        if (kr != kIOReturnSuccess || !plugin) { lastkr = kr; stage = "plug-in"; continue; }
        SCSITaskDeviceInterface **dev = NULL;
        HRESULT hr = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOSCSITaskDeviceInterfaceID), (LPVOID *)&dev);
        if (hr != S_OK || !dev) { IODestroyPlugInInterface(plugin); lastkr = kIOReturnUnsupported; stage = "interface"; continue; }
        kr = (*dev)->ObtainExclusiveAccess(dev);
        if (kr != kIOReturnSuccess) {
            (*dev)->Release(dev); IODestroyPlugInInterface(plugin);
            lastkr = kr; stage = "exclusive access"; continue;
        }
        d->plugin = plugin; d->dev = dev; d->exclusive = 1; d->service = mine[i];
        for (int j = 0; j < m; j++) if (j != i) IOObjectRelease(mine[j]);
        *out = d;
        return 0;
    }
    set_err(err, errlen, "Could not open the logger (%s step, IOKit error 0x%x, %d candidate(s)). "
                         "If its disk is still shown in Finder, eject it and try again.", stage, (unsigned)lastkr, m);
    for (int j = 0; j < m; j++) IOObjectRelease(mine[j]);
    tz_close(d);
    return 3;
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
