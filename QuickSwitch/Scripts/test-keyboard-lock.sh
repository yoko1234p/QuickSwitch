#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK_FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/quickswitch-keyboard-lock.XXXXXX")"
trap 'rm -rf "$LOCK_FIXTURE"' EXIT
LOCK_SOURCE_SUM="$(/usr/bin/shasum -a 256 "$TASK_ROOT/Sources/QuickSwitchNative/KeyboardLock.m" "$TASK_ROOT/Sources/QuickSwitchNative/KeyboardEscapePolicy.h")"
LOCK_SOURCE_SHA="$(printf '%s' "$LOCK_SOURCE_SUM" | /usr/bin/shasum -a 256)"
LOCK_SOURCE_SHA="${LOCK_SOURCE_SHA%% *}"
cat > "$LOCK_FIXTURE/fixture.m" <<'OBJC'
#import <Foundation/Foundation.h>
#import <ApplicationServices/ApplicationServices.h>
#import <mach/mach_time.h>
#import <stdatomic.h>
// Only a plain Mach port is created. All CG event-tap creation/enable/query and trust calls
// below are intercepted, and no synthetic event is posted to the user's session.
static _Atomic(double) fixtureTime = 100;
static _Atomic(bool) fixtureTrusted = true, fixtureEnabled = false;
static bool failTap, failSource, failEnable;
static int fakeTapCreations, fakeEnables;
static BOOL fakeTrust(void) { return atomic_load(&fixtureTrusted); }
static uint64_t fakeContinuousTime(void) {
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    return (uint64_t)(atomic_load(&fixtureTime) * 1e9 * tb.denom / tb.numer);
}
static CFMachPortRef fakeCreateTap(CGEventTapLocation location, CGEventTapPlacement place,
                                 CGEventTapOptions options, CGEventMask mask, CGEventTapCallBack callback, void *info) {
    fakeTapCreations++;
    return failTap ? NULL : CFMachPortCreate(kCFAllocatorDefault, NULL, NULL, NULL);
}
static void fakeEnable(CFMachPortRef tap, bool enabled) { fakeEnables++; atomic_store(&fixtureEnabled, enabled && !failEnable); }
static bool fakeIsEnabled(CFMachPortRef tap) { return atomic_load(&fixtureEnabled); }
static CFRunLoopSourceRef fakeCreateSource(CFAllocatorRef allocator, CFMachPortRef tap, CFIndex order) {
    return failSource ? NULL : CFMachPortCreateRunLoopSource(allocator, tap, order);
}
#define AXIsProcessTrusted fakeTrust
#define mach_continuous_time fakeContinuousTime
#define CGEventTapCreate fakeCreateTap
#define CGEventTapEnable fakeEnable
#define CGEventTapIsEnabled fakeIsEnabled
#define CFMachPortCreateRunLoopSource fakeCreateSource
#import "KeyboardLock.m"

static int checks, failures;
static void check(BOOL value, const char *label) {
    checks++;
    if (!value) { failures++; fprintf(stderr, "FAIL: %s\n", label); }
}
static void sendKey(CGEventType type, CGKeyCode code, bool repeat, uint64_t token) {
    CGEventRef event = CGEventCreateKeyboardEvent(NULL, code, type == kCGEventKeyDown);
    CGEventSetIntegerValueField(event, kCGKeyboardEventAutorepeat, repeat);
    keyboardCallback(NULL, type, event, (void *)(uintptr_t)token);
    CFRelease(event);
}
static void pressEscape(uint64_t token) {
    sendKey(kCGEventKeyDown, 53, false, token);
    sendKey(kCGEventKeyUp, 53, false, token);
    atomic_store(&fixtureTime, atomic_load(&fixtureTime) + 0.1);
}
int main(void) { @autoreleasepool {
    check(!QSKeyboardIsLocked() && QSKeyboardLockGeneration() == 0, "initial state");
    for (NSNumber *duration in @[@0, @4.9, @601, @(NAN), @(INFINITY)])
        check(!QSStartKeyboardLockWithTimeout(duration.doubleValue), "invalid timeout rejected");
    check(fakeTapCreations == 0, "invalid timeout creates no tap");
    atomic_store(&fixtureTrusted, false);
    check(!QSStartKeyboardLock(), "missing trust fails");
    atomic_store(&fixtureTrusted, true);
    failTap = true;
    check(!QSStartKeyboardLock(), "tap creation failure");
    check(!QSKeyboardIsLocked(), "tap failure leaves no lock");
    failTap = false; failSource = true;
    check(!QSStartKeyboardLock(), "source creation failure");
    check(!QSKeyboardIsLocked(), "source failure leaves no lock");
    failSource = false;
    failEnable = true;
    check(!QSStartKeyboardLock(), "failed enable reports no lock");
    check(!QSKeyboardIsLocked() && keyboardSource == NULL, "failed enable releases port and source");
    failEnable = false;
    check(QSStartKeyboardLockWithTimeout(60), "start succeeds with fake tap");
    uint64_t first = QSKeyboardLockGeneration();
    double deadline = keyboardDeadline;
    check(first != 0 && QSKeyboardIsLocked(), "active generation");
    atomic_store(&fixtureTime, 102);
    check(QSStartKeyboardLockWithTimeout(600), "repeated on succeeds");
    check(QSKeyboardLockGeneration() == first && keyboardDeadline == deadline, "on neither toggles nor extends");
    check(fabs(QSKeyboardLockSecondsRemaining() - 58) < 0.001, "remaining uses monotonic deadline");
    sendKey(kCGEventKeyDown, 53, false, first);
    for (int i = 0; i < 8; i++) sendKey(kCGEventKeyDown, 53, true, first);
    sendKey(kCGEventKeyUp, 53, false, first);
    check(QSKeyboardIsLocked(), "held escape not three presses");
    sendKey(kCGEventKeyUp, 53, false, first);
    check(escapePolicy.presses == 1, "duplicate release not counted");
    atomic_store(&fixtureTime, 104);
    pressEscape(first);
    check(escapePolicy.presses == 1, "expired escape sequence resets");
    pressEscape(first);
    check(QSKeyboardIsLocked(), "two presses retain lock");
    pressEscape(first);
    check(!QSKeyboardIsLocked(), "three distinct presses unlock");

    NSMutableArray<NSDictionary *> *notifications = [NSMutableArray array];
    id observer = [[NSNotificationCenter defaultCenter] addObserverForName:QSKeyboardLockDidStopNotification
        object:nil queue:nil usingBlock:^(NSNotification *n) { [notifications addObject:n.userInfo]; }];
    check(QSStartKeyboardLockWithTimeout(30), "next session starts");
    uint64_t second = QSKeyboardLockGeneration();
    check(second != first, "new generation distinct");
    stopKeyboardGeneration(first, @"stale");
    check(QSKeyboardLockGeneration() == second, "stale stop cannot unlock new session");
    keyboardCallback(NULL, kCGEventTapDisabledByTimeout, NULL, (void *)(uintptr_t)first);
    check(QSKeyboardLockGeneration() == second, "stale disabled event cannot unlock new session");
    int enablesBefore = fakeEnables;
    keyboardCallback(NULL, kCGEventTapDisabledByTimeout, NULL, (void *)(uintptr_t)second);
    check(!QSKeyboardIsLocked(), "OS timeout fails open");
    check(fakeEnables == enablesBefore + 1 && !atomic_load(&fixtureEnabled), "never rearms disabled blocker");
    check(QSStartKeyboardLockWithTimeout(5), "deadline session starts");
    uint64_t third = QSKeyboardLockGeneration();
    atomic_store(&fixtureTime, keyboardDeadline + 1);
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        checkKeyboardWatchdog(third);
        dispatch_semaphore_signal(done);
    });
    check(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0,
        "watchdog completes while main thread blocked");
    check(!QSKeyboardIsLocked(), "independent watchdog unlocks after deadline");
    check(QSStartKeyboardLockWithTimeout(60), "permission session starts");
    atomic_store(&fixtureTrusted, false);
    checkKeyboardWatchdog(QSKeyboardLockGeneration());
    check(!QSKeyboardIsLocked(), "permission loss fails open");
    atomic_store(&fixtureTrusted, true);
    check(QSStartKeyboardLock(), "disabled tap session starts");
    atomic_store(&fixtureEnabled, false);
    checkKeyboardWatchdog(QSKeyboardLockGeneration());
    check(!QSKeyboardIsLocked(), "disabled tap watcher fails open");
    check(QSStartKeyboardLock(), "manual session starts");
    QSStopKeyboardLock(); QSStopKeyboardLock();
    check(!QSKeyboardIsLocked() && QSKeyboardLockSecondsRemaining() == 0, "manual stop is idempotent");
    check(keyboardWatchdog == nil && keyboardSource == NULL && keyboardTap == NULL, "all owned resources released");
    check(QSStartKeyboardLock(), "notification freshness session starts");
    uint64_t current = QSKeyboardLockGeneration();
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.03, false);
    check(QSKeyboardLockGeneration() == current, "queued old notifications do not change current lock");
    check(notifications.count >= 5, "stop notifications delivered");
    check([notifications.firstObject[@"generation"] unsignedLongLongValue] == first, "notification identifies stopped session");
    QSStopKeyboardLock();
    [[NSNotificationCenter defaultCenter] removeObserver:observer];
    printf("{\"assertions\":%d,\"failures\":%d,\"realEventTaps\":0,\"postedInputEvents\":0,\"sourceSHA256\":\"%s\"}\n",
        checks, failures, getenv("QS_LOCK_SOURCE_SHA"));
} return failures ? 1 : 0; }
OBJC
xcrun clang -fobjc-arc -Werror -I "$TASK_ROOT/Sources/QuickSwitchNative" -I "$TASK_ROOT/Sources/QuickSwitchNative/include" \
    -framework Foundation -framework ApplicationServices "$LOCK_FIXTURE/fixture.m" -o "$LOCK_FIXTURE/fixture"
if /usr/bin/nm -u "$LOCK_FIXTURE/fixture" | rg '_(CGEventTapCreate|CGEventTapEnable|CGEventTapIsEnabled|CGEventPost)' >/dev/null; then
    echo 'Fixture unexpectedly links a real input-blocking or event-posting entry point.' >&2
    exit 3
fi
LOCK_FINAL_SUM="$(/usr/bin/shasum -a 256 "$TASK_ROOT/Sources/QuickSwitchNative/KeyboardLock.m" "$TASK_ROOT/Sources/QuickSwitchNative/KeyboardEscapePolicy.h")"
[ "$LOCK_SOURCE_SUM" = "$LOCK_FINAL_SUM" ] || { echo 'Keyboard source changed during fixture compilation.' >&2; exit 3; }
QS_LOCK_SOURCE_SHA="$LOCK_SOURCE_SHA" "$LOCK_FIXTURE/fixture"
