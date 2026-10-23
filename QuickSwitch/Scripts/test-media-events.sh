#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MEDIA_FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/quickswitch-media-events.XXXXXX")"
trap 'rm -rf "$MEDIA_FIXTURE"' EXIT
MEDIA_SOURCE_SUM="$(/usr/bin/shasum -a 256 "$TASK_ROOT/Sources/QuickSwitchNative/MediaRead.m")"
MEDIA_SOURCE_SHA="${MEDIA_SOURCE_SUM%% *}"
cat > "$MEDIA_FIXTURE/fixture.m" <<'OBJC'
#import <AppKit/AppKit.h>
#import <CoreServices/CoreServices.h>
@interface MediaApplication : NSObject
@property (nonatomic, assign, getter=isTerminated) BOOL terminated;
@property (nonatomic, assign) pid_t processIdentifier;
@property (nonatomic, copy) NSString *bundleIdentifier;
@end
@implementation MediaApplication
@end
static MediaApplication *application;
static NSArray *applications;
static NSString *scenario;
static int sends, permissionCalls, stateReads, identityReads, checks, failures;
static BOOL permissionAllowed, lastPrompt, terminateOnPermission;
static NSMutableArray *events;
static NSArray *fixtureApplications(NSString *bundle) { return applications; }
static OSStatus fixturePermission(const AEAddressDesc *target, AEEventClass suite, AEEventID event, Boolean prompt) {
    permissionCalls++; lastPrompt = prompt;
    if (target->descriptorType != typeKernelProcessID) failures++;
    if (terminateOnPermission) application.terminated = YES;
    return permissionAllowed ? noErr : errAEEventNotPermitted;
}
static NSAppleEventDescriptor *fixtureSend(NSAppleEventDescriptor *event, double timeout, NSError **error);
#define QS_MEDIA_APPLICATIONS(bundle) fixtureApplications(bundle)
#define QS_MEDIA_SEND(event, duration, outError) fixtureSend(event, duration, outError)
#define AEDeterminePermissionToAutomateTarget fixturePermission
#import "MediaRead.m"
static NSAppleEventDescriptor *fixtureSend(NSAppleEventDescriptor *event, double timeout, NSError **error) {
    sends++;
    AEEventClass suite = [event attributeDescriptorForKeyword:keyEventClassAttr].typeCodeValue;
    AEEventID command = [event attributeDescriptorForKeyword:keyEventIDAttr].typeCodeValue;
    NSAppleEventDescriptor *target = [event attributeDescriptorForKeyword:keyAddressAttr];
    if (target.descriptorType != typeKernelProcessID || timeout <= 0 || timeout > 2) failures++;
    [events addObject:@[@(suite), @(command)]];
    if ([scenario isEqual:@"sendFailure"]) { *error = [NSError errorWithDomain:@"Fixture" code:1 userInfo:nil]; return nil; }
    NSAppleEventDescriptor *reply = [NSAppleEventDescriptor appleEventWithEventClass:kCoreEventClass eventID:kAEAnswer
        targetDescriptor:NSAppleEventDescriptor.nullDescriptor returnID:kAutoGenerateReturnID transactionID:kAnyTransactionID];
    if (suite == 'hook' || suite == 'spfy') {
        if ([scenario isEqual:@"replyError"]) [reply setParamDescriptor:[NSAppleEventDescriptor descriptorWithInt32:-1] forKeyword:keyErrorNumber];
        return reply;
    }
    if (suite != kAECoreSuite || command != kAEGetData) failures++;
    NSAppleEventDescriptor *specifier = [event paramDescriptorForKeyword:keyDirectObject];
    DescType property = [specifier descriptorForKeyword:keyAEKeyData].typeCodeValue;
    NSAppleEventDescriptor *value = nil;
    switch (property) {
        case 'pPlS':
            stateReads++;
            value = [scenario isEqual:@"badState"] ? [NSAppleEventDescriptor descriptorWithString:@"playing"]
                : [NSAppleEventDescriptor descriptorWithEnumCode:([scenario isEqual:@"paused"] || ([scenario isEqual:@"stateChanged"] && stateReads > 1)) ? 'kPSp' : 'kPSP'];
            break;
        case 'pTrk': value = mediaProperty('pTrk', NSAppleEventDescriptor.nullDescriptor); break;
        case 'pPIS': case 'ID  ':
            identityReads++;
            value = [NSAppleEventDescriptor descriptorWithString:([scenario isEqual:@"trackChanged"] && identityReads > 1) ? @"fixture-B" : @"fixture-A"];
            break;
        case 'pnam':
            value = [NSAppleEventDescriptor descriptorWithString:[scenario isEqual:@"oversized"]
                ? [@"a" stringByPaddingToLength:1025 withString:@"a" startingAtIndex:0] : @"Fixture\nTrack"];
            break;
        case 'pArt': value = [NSAppleEventDescriptor descriptorWithString:@"Fixture Artist"]; break;
        default: failures++; return nil;
    }
    [reply setParamDescriptor:value forKeyword:keyDirectObject];
    return reply;
}
static void check(BOOL condition) { checks++; if (!condition) { failures++; fprintf(stderr,"media fixture check %d failed\n",checks); } }
static void reset(NSString *mode) {
    scenario = mode; sends = permissionCalls = stateReads = identityReads = 0;
    permissionAllowed = YES; lastPrompt = NO; terminateOnPermission = NO;
    application = [MediaApplication new]; application.processIdentifier = 424242;
    application.bundleIdentifier = @"com.apple.Music"; applications = @[application]; events = [NSMutableArray array];
}
int main(void) { @autoreleasepool {
    reset(@"normal"); NSDictionary *value = QSReadMediaSnapshot(@"appleMusic", YES);
    check([value[@"state"] isEqual:@"playing"] && [value[@"status"] isEqual:@"ready"]);
    check([value[@"title"] isEqual:@"Fixture Track"] && [value[@"artist"] isEqual:@"Fixture Artist"]);
    check(permissionCalls == 1 && !lastPrompt && identityReads == 2 && sends == 8);
    for (NSArray *event in events) check([event[0] unsignedIntValue] == kAECoreSuite && [event[1] unsignedIntValue] == kAEGetData);
    reset(@"normal"); value = QSReadMediaSnapshot(@"appleMusic", NO);
    check(sends == 1 && value[@"title"] == nil && !lastPrompt);
    reset(@"paused"); value = QSReadMediaSnapshot(@"appleMusic", YES);
    check([value[@"state"] isEqual:@"paused"] && sends == 1 && value[@"title"] == nil);
    reset(@"trackChanged"); value = QSReadMediaSnapshot(@"appleMusic", YES);
    check([value[@"state"] isEqual:@"playing"] && value[@"title"] == nil && value[@"artist"] == nil);
    reset(@"stateChanged"); value = QSReadMediaSnapshot(@"appleMusic", YES);
    check([value[@"state"] isEqual:@"paused"] && value[@"title"] == nil);
    reset(@"oversized"); value = QSReadMediaSnapshot(@"appleMusic", YES);
    check(value[@"title"] == nil && value[@"artist"] == nil);
    reset(@"normal"); applications = @[]; value = QSReadMediaSnapshot(@"appleMusic", YES);
    check([value[@"state"] isEqual:@"notRunning"] && sends == 0 && permissionCalls == 0);
    reset(@"normal"); permissionAllowed = NO; value = QSReadMediaSnapshot(@"appleMusic", YES);
    check([value[@"status"] isEqual:@"permissionDenied"] && sends == 0 && !lastPrompt);
    reset(@"normal"); terminateOnPermission = YES; value = QSReadMediaSnapshot(@"appleMusic", YES);
    check([value[@"state"] isEqual:@"unknown"] && sends == 0);
    reset(@"badState"); value = QSReadMediaSnapshot(@"appleMusic", YES);
    check([value[@"state"] isEqual:@"unknown"] && value[@"title"] == nil);
    reset(@"sendFailure"); value = QSReadMediaSnapshot(@"appleMusic", YES);
    check([value[@"state"] isEqual:@"unknown"]);
    reset(@"normal"); value = QSReadMediaSnapshot(@"invalid", YES);
    check([value[@"state"] isEqual:@"unknown"] && sends == 0 && permissionCalls == 0);
    reset(@"normal"); application.bundleIdentifier = @"com.unrelated.fixture"; value = QSReadMediaSnapshot(@"appleMusic", YES);
    check([value[@"state"] isEqual:@"notRunning"] && sends == 0);
    reset(@"normal"); value = QSSetMediaPlaying(@"appleMusic", NO);
    check([value[@"success"] boolValue] && lastPrompt && sends == 1);
    check([events[0][0] unsignedIntValue] == 'hook' && [events[0][1] unsignedIntValue] == 'Paus');
    reset(@"normal"); application.bundleIdentifier = @"com.spotify.client"; value = QSSetMediaPlaying(@"spotify", YES);
    check([value[@"success"] boolValue] && [events[0][0] unsignedIntValue] == 'spfy' && [events[0][1] unsignedIntValue] == 'Play');
    reset(@"normal"); applications = @[]; value = QSSetMediaPlaying(@"appleMusic", NO);
    check([value[@"success"] boolValue] && sends == 0 && permissionCalls == 0);
    value = QSSetMediaPlaying(@"appleMusic", YES); check(![value[@"success"] boolValue] && sends == 0);
    reset(@"normal"); terminateOnPermission = YES; value = QSSetMediaPlaying(@"appleMusic", NO);
    check([value[@"success"] boolValue] && sends == 0);
    reset(@"normal"); permissionAllowed = NO; value = QSSetMediaPlaying(@"appleMusic", NO);
    check(![value[@"success"] boolValue] && sends == 0);
    reset(@"replyError"); value = QSSetMediaPlaying(@"appleMusic", YES);
    check(![value[@"success"] boolValue]);
    printf("{\"assertions\":%d,\"failures\":%d,\"realAppleEvents\":0,\"launches\":0,\"systemMutations\":0,\"sourceSHA256\":\"%s\"}\n", checks, failures, getenv("QS_MEDIA_SOURCE_SHA"));
} return failures ? 1 : 0; }
OBJC
xcrun clang -fobjc-arc -Werror -Wno-four-char-constants -I "$TASK_ROOT/Sources/QuickSwitchNative" -I "$TASK_ROOT/Sources/QuickSwitchNative/include" \
    -framework AppKit -framework CoreServices "$MEDIA_FIXTURE/fixture.m" -o "$MEDIA_FIXTURE/fixture"
MEDIA_FINAL_SUM="$(/usr/bin/shasum -a 256 "$TASK_ROOT/Sources/QuickSwitchNative/MediaRead.m")"
[ "$MEDIA_SOURCE_SUM" = "$MEDIA_FINAL_SUM" ] || { echo 'Media source changed during fixture compilation.' >&2; exit 3; }
QS_MEDIA_SOURCE_SHA="$MEDIA_SOURCE_SHA" "$MEDIA_FIXTURE/fixture"
