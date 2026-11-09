// Tzone Config - plain Objective-C/Cocoa build (no Swift runtime dependency).
#import <Cocoa/Cocoa.h>
#include "cscsi.h"

#define OP_READ 0xEC
#define OP_WRITE 0xCE
#define ADDR_WRITE 0x10000000u

static void make_cdb(uint8_t out[12], uint8_t op, uint32_t addr, uint32_t len) {
    memset(out, 0, 12);
    out[0] = op;
    out[2] = (addr >> 24) & 0xFF; out[3] = (addr >> 16) & 0xFF; out[4] = (addr >> 8) & 0xFF; out[5] = addr & 0xFF;
    out[6] = (len >> 16) & 0xFF;  out[7] = (len >> 8) & 0xFF;   out[8] = len & 0xFF;
}

// Fields after "*CMD," up to "#", split on ","; empty array if no valid frame.
static NSArray<NSString *> *parse_cmd(NSData *d) {
    NSString *s = [[NSString alloc] initWithData:d encoding:NSISOLatin1StringEncoding];
    NSRange a = [s rangeOfString:@"*CMD,"], b = [s rangeOfString:@"#"];
    if (a.location == NSNotFound || b.location == NSNotFound || NSMaxRange(a) > b.location) return @[];
    NSString *body = [s substringWithRange:NSMakeRange(NSMaxRange(a), b.location - NSMaxRange(a))];
    return [body componentsSeparatedByString:@","];
}

// Returns nil and sets *err on a USB/SCSI failure; otherwise the parsed fields.
static NSArray<NSString *> *dev_read(TzDev *d, uint32_t addr, uint32_t n, NSString **err) {
    uint8_t cdb[12]; make_cdb(cdb, OP_READ, addr, n);
    NSMutableData *buf = [NSMutableData dataWithLength:n];
    char e[256] = {0};
    if (tz_exec(d, cdb, 12, TZ_DIR_IN, buf.mutableBytes, n, e, sizeof e) != 0) {
        *err = [NSString stringWithUTF8String:e];
        return nil;
    }
    return parse_cmd(buf);
}

static BOOL dev_write(TzDev *d, NSString *frame, NSString **err) {
    NSData *payload = [frame dataUsingEncoding:NSASCIIStringEncoding];
    NSMutableData *buf = [payload mutableCopy];
    uint8_t cdb[12]; make_cdb(cdb, OP_WRITE, ADDR_WRITE, (uint32_t)buf.length);
    char e[256] = {0};
    if (tz_exec(d, cdb, 12, TZ_DIR_OUT, buf.mutableBytes, (uint32_t)buf.length, e, sizeof e) != 0) {
        *err = [NSString stringWithUTF8String:e];
        return NO;
    }
    return YES;
}

static TzDev *open_logger(NSString **err) {
    char e[256] = {0};
    TzDev *d = NULL;
    if (tz_open("Tzone", "DataLogger", &d, e, sizeof e) != 0) { *err = [NSString stringWithUTF8String:e]; return NULL; }
    return d;
}

static NSString *local_time_from_fields(NSArray<NSString *> *p) {
    if (p.count != 7) return @"";
    NSCalendar *cal = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    cal.timeZone = [NSTimeZone timeZoneWithName:@"UTC"];
    NSDateComponents *c = [NSDateComponents new];
    NSInteger y = [p[1] integerValue];
    c.year = y < 100 ? 2000 + y : y; c.month = [p[2] integerValue]; c.day = [p[3] integerValue];
    c.hour = [p[4] integerValue]; c.minute = [p[5] integerValue]; c.second = [p[6] integerValue];
    NSDate *date = [cal dateFromComponents:c];
    if (!date) return @"";
    NSDateFormatter *f = [NSDateFormatter new];
    f.dateFormat = @"yyyy/MM/dd HH:mm:ss";
    return [f stringFromDate:date];
}

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (strong) NSWindow *window;
@property (strong) NSTextField *model, *firmware, *devID, *devTime, *ssid, *pass, *status;
@property (strong) NSButton *readBtn, *saveBtn, *copyBtn;
@property BOOL busy;
@end

@implementation AppDelegate

- (NSTextField *)labelAt:(CGFloat)y text:(NSString *)t {
    NSTextField *l = [NSTextField labelWithString:t];
    l.frame = NSMakeRect(20, y, 100, 22);
    l.alignment = NSTextAlignmentRight;
    [self.window.contentView addSubview:l];
    return l;
}

- (NSTextField *)fieldAt:(CGFloat)y editable:(BOOL)e {
    NSTextField *f = [[NSTextField alloc] initWithFrame:NSMakeRect(130, y, 280, 22)];
    f.editable = e; f.bezeled = YES; f.bezelStyle = NSTextFieldSquareBezel;
    f.drawsBackground = YES;
    [self.window.contentView addSubview:f];
    return f;
}

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 520, 340)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"Tzone Configuration Tool";
    CGFloat y = 295;
    [self labelAt:y text:@"Model"];         self.model    = [self fieldAt:y editable:NO]; y -= 34;
    [self labelAt:y text:@"Firmware"];      self.firmware = [self fieldAt:y editable:NO]; y -= 34;
    [self labelAt:y text:@"Device ID"];     self.devID    = [self fieldAt:y editable:NO]; y -= 34;
    [self labelAt:y text:@"Device time"];   self.devTime  = [self fieldAt:y editable:NO]; y -= 44;
    [self labelAt:y text:@"WiFi name"];     self.ssid     = [self fieldAt:y editable:YES]; y -= 34;
    [self labelAt:y text:@"WiFi password"]; self.pass     = [self fieldAt:y editable:YES]; y -= 50;

    self.copyBtn = [NSButton buttonWithTitle:@"Copy ID" target:self action:@selector(copyID:)];
    self.copyBtn.frame = NSMakeRect(420, 229, 85, 28);
    self.readBtn = [NSButton buttonWithTitle:@"Read" target:self action:@selector(doRead:)];
    self.readBtn.frame = NSMakeRect(330, y, 80, 30);
    self.saveBtn = [NSButton buttonWithTitle:@"Save" target:self action:@selector(doSave:)];
    self.saveBtn.frame = NSMakeRect(420, y, 80, 30);
    self.saveBtn.enabled = NO;
    self.status = [NSTextField wrappingLabelWithString:@"Plug in the logger and press Read."];
    self.status.frame = NSMakeRect(20, y - 4, 300, 40);
    for (NSView *v in @[self.copyBtn, self.readBtn, self.saveBtn, self.status]) [self.window.contentView addSubview:v];

    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)a { return YES; }

- (void)setBusy:(BOOL)b { _busy = b; self.readBtn.enabled = !b; }

- (void)fail:(NSString *)msg {
    self.busy = NO;
    self.status.stringValue = @"Failed.";
    NSAlert *a = [NSAlert new];
    a.messageText = @"Something went wrong";
    a.informativeText = msg;
    [a runModal];
}

- (void)copyID:(id)s {
    [[NSPasteboard generalPasteboard] clearContents];
    [[NSPasteboard generalPasteboard] setString:self.devID.stringValue forType:NSPasteboardTypeString];
    self.status.stringValue = @"ID copied to clipboard.";
}

- (void)doRead:(id)s {
    if (self.busy) return;
    self.busy = YES; self.saveBtn.enabled = NO;
    self.status.stringValue = @"Reading device…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *err = nil;
        TzDev *d = open_logger(&err);
        if (!d) { dispatch_async(dispatch_get_main_queue(), ^{ [self fail:err]; }); return; }
        NSString *hw = @"", *fw = @"", *ident = @"", *time = @"", *sid = @"", *pw = @"";
        BOOL wifi = NO;
        NSArray<NSString *> *p = dev_read(d, 0x03000911, 64, &err);
        if (p && p.count > 1) {
            hw = p[1];
            NSString *m = [[hw uppercaseString] componentsSeparatedByString:@"_"].firstObject;
            wifi = [@[@"WF501", @"WF501B", @"WF502", @"WF502B"] containsObject:m];
            NSString *last = p.lastObject;
            if ([[last uppercaseString] hasPrefix:@"V"]) fw = [last substringFromIndex:1];
            if (wifi) {
                NSArray<NSString *> *q = dev_read(d, 0x03000910, 64, &err);
                if (q && q.count > 1) hw = [hw stringByAppendingFormat:@"_%@", q[1]];
            }
            NSArray<NSString *> *r = dev_read(d, 0x03000002, 25, &err);
            if (r && r.count > 1) ident = r[1];
            if (wifi) {
                time = local_time_from_fields(dev_read(d, 0x03000006, 50, &err) ?: @[]);
                NSArray<NSString *> *w = dev_read(d, 0x03000020, 150, &err);
                if (w && w.count == 3) { sid = w[1]; pw = w[2]; }
            }
        } else if (!p) {
            // err already set
        } else {
            err = @"The device did not answer the model query.";
        }
        tz_close(d);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (hw.length == 0) { [self fail:err ?: @"No answer from device."]; return; }
            self.busy = NO;
            self.model.stringValue = hw; self.firmware.stringValue = fw; self.devID.stringValue = ident;
            self.devTime.stringValue = time; self.ssid.stringValue = sid; self.pass.stringValue = pw;
            self.saveBtn.enabled = wifi;
            self.status.stringValue = wifi ? @"Read OK." : @"Device read OK. WiFi settings are only available for WF501/WF502 models.";
        });
    });
}

- (void)doSave:(id)s {
    if (self.busy) return;
    NSString *name = [self.ssid.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSString *pw = [self.pass.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    for (NSArray *pair in @[@[@"WiFi name", name], @[@"WiFi password", pw]]) {
        NSString *v = pair[1];
        NSString *msg = nil;
        if ([v containsString:@"#"] || [v containsString:@","]) msg = @"may not contain '#' or ','.";
        else if (![v canBeConvertedToEncoding:NSASCIIStringEncoding]) msg = @"must use plain ASCII characters.";
        else if (v.length > 63) msg = @"must be at most 63 characters.";
        if (msg) { [self fail:[NSString stringWithFormat:@"%@ %@", pair[0], msg]]; return; }
    }
    self.busy = YES;
    self.status.stringValue = @"Writing device…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *err = nil;
        TzDev *d = open_logger(&err);
        if (!d) { dispatch_async(dispatch_get_main_queue(), ^{ [self fail:err]; }); return; }
        NSDateFormatter *f = [NSDateFormatter new];
        f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        f.timeZone = [NSTimeZone timeZoneWithName:@"UTC"];
        f.dateFormat = @"yy,MM,dd,HH,mm,ss";
        BOOL ok = dev_write(d, @"*000000,003,125,-40,100,0,1#", &err)
               && dev_write(d, [NSString stringWithFormat:@"*000000,006,%@#", [f stringFromDate:[NSDate date]]], &err)
               && dev_write(d, [NSString stringWithFormat:@"*000000,020,%@,%@#", name, pw], &err);
        NSString *time = @"", *sid = name, *wp = pw;
        if (ok) {
            time = local_time_from_fields(dev_read(d, 0x03000006, 50, &err) ?: @[]);
            NSArray<NSString *> *w = dev_read(d, 0x03000020, 150, &err);
            if (w && w.count == 3) { sid = w[1]; wp = w[2]; }
        }
        tz_close(d);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ok) { [self fail:err ?: @"Write failed."]; return; }
            self.busy = NO;
            self.devTime.stringValue = time; self.ssid.stringValue = sid; self.pass.stringValue = wp;
            self.status.stringValue = @"Saved. The device clock was set to the current time.";
        });
    });
}
@end

static AppDelegate *gDelegate;

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        // Menus (needed for Cmd-Q and for copy/paste in text fields)
        NSMenu *bar = [NSMenu new];
        NSMenuItem *appItem = [NSMenuItem new]; [bar addItem:appItem];
        NSMenu *appMenu = [NSMenu new];
        [appMenu addItemWithTitle:@"Quit Tzone Config" action:@selector(terminate:) keyEquivalent:@"q"];
        appItem.submenu = appMenu;
        NSMenuItem *editItem = [NSMenuItem new]; [bar addItem:editItem];
        NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Edit"];
        [edit addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
        [edit addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
        [edit addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
        [edit addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
        editItem.submenu = edit;
        app.mainMenu = bar;

        gDelegate = [AppDelegate new];
        app.delegate = gDelegate;
        [app activateIgnoringOtherApps:YES];
        [app run];
    }
    return 0;
}
