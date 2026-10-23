#import "QuickSwitchNative.h"
#import "KeyboardEscapePolicy.h"
#import <ApplicationServices/ApplicationServices.h>
#import <mach/mach_time.h>
#import <os/lock.h>

NSNotificationName const QSKeyboardLockDidStopNotification = @"QuickSwitch.KeyboardLockDidStop";
static os_unfair_lock keyboardStateLock = OS_UNFAIR_LOCK_INIT;
static CFMachPortRef keyboardTap;
static CFRunLoopSourceRef keyboardSource;
static dispatch_source_t keyboardWatchdog;
static uint64_t keyboardGeneration;
static double keyboardDeadline;
static QSEscapePolicy escapePolicy;

static double keyboardMonotonicTime(void) {
    static mach_timebase_info_data_t timebase;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&timebase); });
    return (double)mach_continuous_time() * timebase.numer / timebase.denom / 1e9;
}

static void stopKeyboardGeneration(uint64_t expected, NSString *reason) {
    os_unfair_lock_lock(&keyboardStateLock);
    if (!keyboardTap || (expected && expected != keyboardGeneration)) {
        os_unfair_lock_unlock(&keyboardStateLock);
        return;
    }
    uint64_t stopped = keyboardGeneration;
    CFMachPortRef oldTap = keyboardTap;
    CFRunLoopSourceRef oldSource = keyboardSource;
    dispatch_source_t oldWatchdog = keyboardWatchdog;
    keyboardTap = NULL;
    keyboardSource = NULL;
    keyboardWatchdog = nil;
    keyboardDeadline = 0;
    escapePolicy = (QSEscapePolicy){0};
    os_unfair_lock_unlock(&keyboardStateLock);

    if (oldWatchdog) dispatch_source_cancel(oldWatchdog);
    CGEventTapEnable(oldTap, false);
    CFMachPortInvalidate(oldTap);
    if (oldSource) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), oldSource, kCFRunLoopCommonModes);
        CFRelease(oldSource);
    }
    CFRelease(oldTap);
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:QSKeyboardLockDidStopNotification object:nil
            userInfo:@{@"generation": @(stopped), @"reason": reason}];
    });
}

void QSStopKeyboardLock(void) { stopKeyboardGeneration(0, @"manual"); }

BOOL QSKeyboardIsLocked(void) {
    os_unfair_lock_lock(&keyboardStateLock);
    BOOL active = keyboardTap != NULL;
    os_unfair_lock_unlock(&keyboardStateLock);
    return active;
}
uint64_t QSKeyboardLockGeneration(void) {
    os_unfair_lock_lock(&keyboardStateLock);
    uint64_t result = keyboardTap ? keyboardGeneration : 0;
    os_unfair_lock_unlock(&keyboardStateLock);
    return result;
}
NSTimeInterval QSKeyboardLockSecondsRemaining(void) {
    os_unfair_lock_lock(&keyboardStateLock);
    double remaining = keyboardTap ? fmax(0, keyboardDeadline - keyboardMonotonicTime()) : 0;
    os_unfair_lock_unlock(&keyboardStateLock);
    return remaining;
}

static void checkKeyboardWatchdog(uint64_t expected) {
    os_unfair_lock_lock(&keyboardStateLock);
    if (!keyboardTap || expected != keyboardGeneration) {
        os_unfair_lock_unlock(&keyboardStateLock);
        return;
    }
    double deadline = keyboardDeadline;
    CFMachPortRef tap = keyboardTap;
    CFRetain(tap);
    os_unfair_lock_unlock(&keyboardStateLock);
    NSString *reason = nil;
    if (keyboardMonotonicTime() >= deadline) reason = @"deadline";
    else if (!AXIsProcessTrusted()) reason = @"permissionLost";
    else if (!CFMachPortIsValid(tap) || !CGEventTapIsEnabled(tap)) reason = @"systemDisabled";
    CFRelease(tap);
    if (reason) stopKeyboardGeneration(expected, reason);
}

static CGEventRef keyboardCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *info) {
    uint64_t expected = (uint64_t)(uintptr_t)info;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        // A disabled blocker must fail open. Never revive it after a stalled run loop.
        stopKeyboardGeneration(expected, @"systemDisabled");
        return event;
    }
    os_unfair_lock_lock(&keyboardStateLock);
    if (!keyboardTap || expected != keyboardGeneration) {
        os_unfair_lock_unlock(&keyboardStateLock);
        return event;
    }
    BOOL shouldStop = NO;
    if (event && (type == kCGEventKeyDown || type == kCGEventKeyUp)) {
        shouldStop = QSConsumeEmergencyEscape(&escapePolicy, type == kCGEventKeyDown,
            (unsigned int)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode),
            CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat) != 0, keyboardMonotonicTime());
    }
    os_unfair_lock_unlock(&keyboardStateLock);
    if (shouldStop) stopKeyboardGeneration(expected, @"emergencyEscape");
    return NULL;
}

BOOL QSStartKeyboardLock(void) { return QSStartKeyboardLockWithTimeout(120); }

BOOL QSStartKeyboardLockWithTimeout(NSTimeInterval timeout) {
    if (!NSThread.isMainThread || !isfinite(timeout) || timeout < 5 || timeout > 600 || !AXIsProcessTrusted()) return NO;
    os_unfair_lock_lock(&keyboardStateLock);
    if (keyboardTap) {
        os_unfair_lock_unlock(&keyboardStateLock);
        return YES; // Repeated On neither toggles nor extends the emergency deadline.
    }
    uint64_t expected = ++keyboardGeneration;
    if (!expected) expected = ++keyboardGeneration;
    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp)
        | CGEventMaskBit(kCGEventFlagsChanged);
    CFMachPortRef tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
        kCGEventTapOptionDefault, mask, keyboardCallback, (void *)(uintptr_t)expected);
    if (!tap) { os_unfair_lock_unlock(&keyboardStateLock); return NO; }
    CFRunLoopSourceRef source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0);
    if (!source) {
        CFMachPortInvalidate(tap);
        CFRelease(tap);
        os_unfair_lock_unlock(&keyboardStateLock);
        return NO;
    }
    keyboardTap = tap;
    keyboardSource = source;
    keyboardDeadline = keyboardMonotonicTime() + timeout;
    escapePolicy = (QSEscapePolicy){0};
    CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
    CGEventTapEnable(tap, true);
    if (!CGEventTapIsEnabled(tap)) {
        keyboardTap = NULL;
        keyboardSource = NULL;
        keyboardDeadline = 0;
        CFMachPortInvalidate(tap);
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
        CFRelease(source);
        CFRelease(tap);
        os_unfair_lock_unlock(&keyboardStateLock);
        return NO;
    }
    keyboardWatchdog = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
    dispatch_source_set_timer(keyboardWatchdog, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
        NSEC_PER_SEC, NSEC_PER_MSEC * 50);
    dispatch_source_set_event_handler(keyboardWatchdog, ^{ checkKeyboardWatchdog(expected); });
    dispatch_resume(keyboardWatchdog);
    os_unfair_lock_unlock(&keyboardStateLock);
    return YES;
}
