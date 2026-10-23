#import "QuickSwitchNative.h"
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <unistd.h>
#import <math.h>

// Optional improvement over the original's macOS >=15 cached shortcut state.
// Exact encodings were observed on macOS 27; class presence does not imply authorization.
// The executable invokes this bridge in a bounded child process, never on the UI thread.
static BOOL QSFocusMatches(id receiver, NSString *name, const char *encoding) {
    if (!receiver) return NO;
    Method method = class_getInstanceMethod(object_getClass(receiver), NSSelectorFromString(name));
    return method && strcmp(method_getTypeEncoding(method), encoding) == 0;
}
static BOOL QSFocusLoad(void) {
    static void *framework;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        framework = dlopen("/System/Library/PrivateFrameworks/DoNotDisturb.framework/DoNotDisturb", RTLD_LAZY | RTLD_LOCAL);
    });
    return framework != NULL;
}
static NSDictionary *QSFocusUnavailable(NSString *status, NSError *error) {
    return @{@"status": status, @"errorDomain": error.domain ?: @"", @"errorCode": @(error.code), @"mutationAttempted": @NO};
}
static id QSFocusService(NSString *name) {
    Class cls = NSClassFromString(name);
    NSString *factory = @"serviceForClientIdentifier:";
    if (!QSFocusMatches(cls, factory, "@24@0:8@16")) return nil;
    // Never claim an Apple client's identifier or add restricted system entitlements.
    return ((id (*)(id, SEL, id))objc_msgSend)(cls, NSSelectorFromString(factory), @"local.pakwingho.quickswitch");
}
static NSString *QSDefaultFocusIdentifier(void) {
    Class cls = NSClassFromString(@"DNDMode");
    if (!QSFocusMatches(cls, @"defaultMode", "@16@0:8")) return nil;
    id mode = ((id (*)(id, SEL))objc_msgSend)(cls, NSSelectorFromString(@"defaultMode"));
    if (!QSFocusMatches(mode, @"modeIdentifier", "@16@0:8")) return nil;
    id identifier = ((id (*)(id, SEL))objc_msgSend)(mode, NSSelectorFromString(@"modeIdentifier"));
    return [identifier isKindOfClass:NSString.class] && [identifier isEqual:@"com.apple.donotdisturb.mode.default"] ? identifier : nil;
}
static NSDictionary *QSFocusSnapshotForState(id state, NSString *identifier) {
    if (!QSFocusMatches(state, @"isActive", "B16@0:8") || !QSFocusMatches(state, @"activeModeIdentifiers", "@16@0:8"))
        return QSFocusUnavailable(@"abiMismatch", nil);
    BOOL active = ((BOOL (*)(id, SEL))objc_msgSend)(state, NSSelectorFromString(@"isActive"));
    id modes = ((id (*)(id, SEL))objc_msgSend)(state, NSSelectorFromString(@"activeModeIdentifiers"));
    if (modes && ![modes isKindOfClass:NSSet.class] && ![modes isKindOfClass:NSArray.class])
        return QSFocusUnavailable(@"unknown", nil);
    if (modes && (![modes respondsToSelector:@selector(count)] || [modes count] > 32))
        return QSFocusUnavailable(@"unknown", nil);
    if ((active && [modes count] == 0) || (!active && [modes count] != 0))
        return QSFocusUnavailable(@"unknown", nil);
    for (id mode in modes) {
        if (![mode isKindOfClass:NSString.class] || [mode length] == 0 || [mode length] > 512)
            return QSFocusUnavailable(@"unknown", nil);
    }
    if ([modes isKindOfClass:NSArray.class] && [NSSet setWithArray:modes].count != [modes count])
        return QSFocusUnavailable(@"unknown", nil);
    BOOL dnd = active && [modes containsObject:identifier];
    return @{@"status": @"exact", @"dndEnabled": @(dnd), @"otherFocusActive": @(active && [modes count] > (dnd ? 1 : 0)), @"mutationAttempted": @NO};
}
NSDictionary<NSString *, id> *QSReadFocusState(void) {
    @try {
        if (!QSFocusLoad()) return QSFocusUnavailable(@"unavailable", nil);
        id service = QSFocusService(@"DNDStateService");
        NSString *identifier = QSDefaultFocusIdentifier();
        if (!identifier || !QSFocusMatches(service, @"queryCurrentStateWithError:", "@24@0:8^@16"))
            return QSFocusUnavailable(@"abiMismatch", nil);
        NSError *error = nil;
        id state = ((id (*)(id, SEL, NSError *__autoreleasing *))objc_msgSend)(service, NSSelectorFromString(@"queryCurrentStateWithError:"), &error);
        if (!state || error) return QSFocusUnavailable(@"denied", error);
        return QSFocusSnapshotForState(state, identifier);
    } @catch (NSException *exception) {
        return QSFocusUnavailable(@"abiMismatch", nil);
    }
}
NSDictionary<NSString *, id> *QSSetFocusEnabled(BOOL enabled, NSTimeInterval duration) {
    @try {
        if (!isfinite(duration) || duration < 0 || duration > 604800) return QSFocusUnavailable(@"invalidDuration", nil);
        NSDictionary *before = QSReadFocusState();
        if (![before[@"status"] isEqual:@"exact"]) return before;
        if ([before[@"dndEnabled"] boolValue] == enabled && (!enabled || duration == 0))
            return @{@"status": @"exact", @"dndEnabled": @(enabled), @"mutationAttempted": @NO, @"readbackVerified": @YES};
        // Current exported API only invalidates whichever assertion is active at call time.
        // A query followed by that call cannot bind the operation to the DND assertion:
        // another Focus might activate in between. Use the system's DND-specific shortcut instead.
        if (!enabled) return QSFocusUnavailable(@"unavailable", nil);
        id service = QSFocusService(@"DNDModeAssertionService");
        NSString *operation = @"takeModeAssertionWithDetails:error:";
        if (!QSFocusMatches(service, operation, "@32@0:8@16^@24"))
            return QSFocusUnavailable(@"abiMismatch", nil);
        NSError *error = nil;
        id response = nil;
        if (enabled) {
            Class lifetimeClass = NSClassFromString(@"DNDModeAssertionLifetime");
            NSString *lifetimeSelector = duration > 0 ? @"lifetimeWithDuration:" : @"lifetimeForUserRequest";
            if (!QSFocusMatches(lifetimeClass, lifetimeSelector, duration > 0 ? "@24@0:8d16" : "@16@0:8"))
                return QSFocusUnavailable(@"abiMismatch", nil);
            id lifetime = duration > 0
                ? ((id (*)(id, SEL, double))objc_msgSend)(lifetimeClass, NSSelectorFromString(lifetimeSelector), duration)
                : ((id (*)(id, SEL))objc_msgSend)(lifetimeClass, NSSelectorFromString(lifetimeSelector));
            Class detailsClass = NSClassFromString(@"DNDModeAssertionDetails");
            NSString *detailsSelector = @"userRequestedAssertionDetailsWithIdentifier:modeIdentifier:lifetime:";
            if (!lifetime || !QSFocusMatches(detailsClass, detailsSelector, "@40@0:8@16@24@32"))
                return QSFocusUnavailable(@"abiMismatch", nil);
            id details = ((id (*)(id, SEL, id, id, id))objc_msgSend)(detailsClass, NSSelectorFromString(detailsSelector),
                [@"local.pakwingho.quickswitch." stringByAppendingString:NSUUID.UUID.UUIDString], QSDefaultFocusIdentifier(), lifetime);
            if (!details) return QSFocusUnavailable(@"unavailable", nil);
            response = ((id (*)(id, SEL, id, NSError *__autoreleasing *))objc_msgSend)(service, NSSelectorFromString(operation), details, &error);
        }
        if (error || !response)
            return @{@"status": @"failed", @"errorDomain": error.domain ?: @"", @"errorCode": @(error.code), @"mutationAttempted": @YES};
        for (NSUInteger attempt = 0; attempt < 4; attempt++) {
            NSDictionary *after = QSReadFocusState();
            if ([after[@"status"] isEqual:@"exact"] && [after[@"dndEnabled"] boolValue] == enabled)
                return @{@"status": @"exact", @"dndEnabled": @(enabled), @"mutationAttempted": @YES, @"readbackVerified": @YES};
            usleep(100000);
        }
        return @{@"status": @"unverified", @"mutationAttempted": @YES};
    } @catch (NSException *exception) {
        // A thrown private call may already have changed state; never run a fallback automatically.
        return @{@"status": @"abiMismatch", @"mutationAttempted": @YES};
    }
}
