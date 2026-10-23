#import "QuickSwitchNative.h"
#import <IOBluetooth/IOBluetooth.h>
#import <ApplicationServices/ApplicationServices.h>
#import <dlfcn.h>
#import <CoreServices/CoreServices.h>
#import <objc/message.h>
#import <objc/runtime.h>

NSArray<NSDictionary<NSString *, id> *> *QSHeadphones(void) {
    NSMutableArray *result = [NSMutableArray array];
    for (IOBluetoothDevice *device in [IOBluetoothDevice pairedDevices]) {
        // Audio-video major class 0x04; include unknown class because some headphones misreport it.
        if (device.deviceClassMajor != 4 && device.deviceClassMajor != 0) continue;
        [result addObject:@{@"name": device.name ?: @"Bluetooth device", @"address": device.addressString ?: @"", @"connected": @(device.isConnected)}];
    }
    return result;
}
int QSSetHeadphoneConnection(NSString *address, BOOL connected) {
    IOBluetoothDevice *device = [IOBluetoothDevice deviceWithAddressString:address];
    if (!device) return -1;
    return connected ? [device openConnection] : [device closeConnection];
}
BOOL QSLockScreen(void) {
    void *framework = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_LAZY);
    if (!framework) return NO;
    void (*lock)(void) = dlsym(framework, "SACLockScreenImmediate");
    if (!lock) { dlclose(framework); return NO; }
    lock();
    dlclose(framework);
    return YES;
}
// ABI established by OneSwitchXPC REA decompilation and the local runtime probe.
// Fail closed when an OS update changes a class or method signature.
typedef struct {
    bool supported;
    bool enabled;
    bool thirdFlag;
    int32_t mode;
    struct { struct { int32_t hour, minute; } from, to; } schedule;
    uint64_t flags;
    bool trailingFlag;
} QSBlueLightStatus;
_Static_assert(sizeof(QSBlueLightStatus) == 40, "CoreBrightness status ABI");
static id displayClient(NSString *name) {
    static void *framework;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ framework = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY); });
    if (!framework) return nil;
    Class cls = NSClassFromString([name isEqualToString:@"nightShift"] ? @"CBBlueLightClient" : @"CBTrueToneClient");
    return cls ? [[cls alloc] init] : nil;
}
static BOOL matchesMethod(id client, SEL selector, const char *encoding) {
    Method method = class_getInstanceMethod([client class], selector);
    return method && strcmp(method_getTypeEncoding(method), encoding) == 0;
}
int QSDisplaySettingState(NSString *name) {
    if (![name isEqualToString:@"nightShift"] && ![name isEqualToString:@"trueTone"]) return -1;
    id client = displayClient(name);
    if (!client) return -1;
    if ([name isEqualToString:@"nightShift"]) {
        SEL selector = NSSelectorFromString(@"getBlueLightStatus:");
        if (!matchesMethod(client, selector, "B24@0:8^{?=BBBi{?={?=ii}{?=ii}}QB}16")) return -1;
        QSBlueLightStatus status = {0};
        BOOL success = ((BOOL(*)(id, SEL, QSBlueLightStatus *))objc_msgSend)(client, selector, &status);
        return success && status.supported ? (status.enabled ? 1 : 0) : -1;
    }
    SEL available = NSSelectorFromString(@"available"), enabled = NSSelectorFromString(@"enabled");
    if (!matchesMethod(client, available, "B16@0:8") || !matchesMethod(client, enabled, "B16@0:8")) return -1;
    if (!((BOOL(*)(id, SEL))objc_msgSend)(client, available)) return -1;
    return ((BOOL(*)(id, SEL))objc_msgSend)(client, enabled) ? 1 : 0;
}
BOOL QSSetDisplaySetting(NSString *name, BOOL enabled) {
    if (QSDisplaySettingState(name) < 0) return NO;
    id client = displayClient(name);
    SEL setter = NSSelectorFromString(@"setEnabled:");
    if (!matchesMethod(client, setter, "B20@0:8B16")) return NO;
    return ((BOOL(*)(id, SEL, BOOL))objc_msgSend)(client, setter, enabled);
}

BOOL QSAutomationIsAuthorized(NSString *bundleIdentifier) {
    AEAddressDesc target = {typeNull, NULL};
    NSData *data = [bundleIdentifier dataUsingEncoding:NSUTF8StringEncoding];
    if (AECreateDesc(typeApplicationBundleID, data.bytes, data.length, &target) != noErr) return NO;
    OSStatus status = AEDeterminePermissionToAutomateTarget(&target, kAECoreSuite, kAEGetData, false);
    AEDisposeDesc(&target);
    return status == noErr;
}
