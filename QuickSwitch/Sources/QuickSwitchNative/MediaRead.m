#import "QuickSwitchNative.h"
#import <AppKit/AppKit.h>
#import <CoreServices/CoreServices.h>
#import <math.h>

#ifndef QS_MEDIA_APPLICATIONS
#define QS_MEDIA_APPLICATIONS(bundle) [NSRunningApplication runningApplicationsWithBundleIdentifier:bundle]
#endif
#ifndef QS_MEDIA_SEND
#define QS_MEDIA_SEND(event, duration, outError) [event sendEventWithOptions:(NSAppleEventSendWaitForReply | NSAppleEventSendNeverInteract | NSAppleEventSendDontRecord | NSAppleEventSendDontAnnotate) timeout:(duration) error:(outError)]
#endif

// Both installed Music.sdef and Spotify.sdef declare these read-only property codes.
// Target a currently running PID, never a bundle address which could launch a player.
static NSAppleEventDescriptor *mediaProperty(DescType property, NSAppleEventDescriptor *container) {
    AEDesc specifier = {typeNull, NULL};
    NSAppleEventDescriptor *key = [NSAppleEventDescriptor descriptorWithTypeCode:property];
    // CreateObjSpecifier's legacy signature is mutable even when disposeInputs is false.
    // These shallow input copies remain owned by their Foundation descriptors.
    AEDesc containerInput = *container.aeDesc, keyInput = *key.aeDesc;
    if (CreateObjSpecifier(cProperty, &containerInput, formPropertyID, &keyInput, false, &specifier) != noErr)
        return nil;
    return [[NSAppleEventDescriptor alloc] initWithAEDescNoCopy:&specifier];
}

static NSAppleEventDescriptor *mediaGet(NSRunningApplication *application, NSAppleEventDescriptor *target,
                                       DescType property, NSAppleEventDescriptor *container, double deadline) {
    if (application.isTerminated || application.processIdentifier <= 0) return nil;
    double remaining = deadline - NSProcessInfo.processInfo.systemUptime;
    if (remaining <= 0) return nil;
    NSAppleEventDescriptor *specifier = mediaProperty(property, container);
    if (!specifier) return nil;
    NSAppleEventDescriptor *event = [NSAppleEventDescriptor appleEventWithEventClass:kAECoreSuite
        eventID:kAEGetData targetDescriptor:target returnID:kAutoGenerateReturnID transactionID:kAnyTransactionID];
    [event setParamDescriptor:specifier forKeyword:keyDirectObject];
    NSError *error = nil;
    NSAppleEventDescriptor *reply = QS_MEDIA_SEND(event, fmin(0.35, remaining), &error);
    if (!reply || error || AEGetDescDataSize(reply.aeDesc) > 32768) return nil;
    NSAppleEventDescriptor *errorNumber = [reply paramDescriptorForKeyword:keyErrorNumber];
    if (errorNumber && errorNumber.int32Value != 0) return nil;
    NSAppleEventDescriptor *value = [reply paramDescriptorForKeyword:keyDirectObject];
    return value && AEGetDescDataSize(value.aeDesc) <= 8192 ? value : nil;
}

static NSString *mediaPlaybackState(NSAppleEventDescriptor *value) {
    if (!value || value.descriptorType != typeEnumerated || AEGetDescDataSize(value.aeDesc) != 4) return nil;
    switch (value.enumCodeValue) {
        case 'kPSP': return @"playing";
        case 'kPSp': case 'kPSS': return @"paused";
        default: return nil;
    }
}

static NSString *mediaText(NSAppleEventDescriptor *value, BOOL *valid) {
    *valid = NO;
    if (!value || AEGetDescDataSize(value.aeDesc) > 8192) return nil;
    if (value.descriptorType == typeNull) { *valid = YES; return nil; }
    if (value.descriptorType != typeUnicodeText && value.descriptorType != typeUTF8Text && value.descriptorType != typeChar)
        return nil;
    NSString *string = value.stringValue;
    if (!string || string.length > 1024) return nil;
    *valid = YES;
    string = [[string componentsSeparatedByCharactersInSet:NSCharacterSet.controlCharacterSet] componentsJoinedByString:@" "];
    string = [string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return string.length ? string : nil;
}

NSDictionary<NSString *, id> *QSReadMediaSnapshot(NSString *player, BOOL includeMetadata) {
    NSString *bundle = [player isEqualToString:@"appleMusic"] ? @"com.apple.Music"
        : [player isEqualToString:@"spotify"] ? @"com.spotify.client" : nil;
    NSMutableDictionary *result = [@{@"player": player ?: @"", @"state": @"unknown", @"status": @"unavailable"} mutableCopy];
    if (!bundle) return result;
    NSRunningApplication *application = nil;
    for (NSRunningApplication *candidate in QS_MEDIA_APPLICATIONS(bundle)) {
        if (!candidate.isTerminated && candidate.processIdentifier > 0 && [candidate.bundleIdentifier isEqualToString:bundle]) {
            application = candidate;
            break;
        }
    }
    if (!application) {
        result[@"state"] = @"notRunning";
        result[@"status"] = @"notRunning";
        return result;
    }
    NSAppleEventDescriptor *target = [NSAppleEventDescriptor descriptorWithProcessIdentifier:application.processIdentifier];
    OSStatus authorization = AEDeterminePermissionToAutomateTarget(target.aeDesc, kAECoreSuite, kAEGetData, false);
    if (authorization != noErr) {
        result[@"status"] = @"permissionDenied";
        return result;
    }
    double deadline = NSProcessInfo.processInfo.systemUptime + 2;
    NSAppleEventDescriptor *root = NSAppleEventDescriptor.nullDescriptor;
    NSString *before = mediaPlaybackState(mediaGet(application, target, 'pPlS', root, deadline));
    if (!before) return result;
    result[@"state"] = before;
    result[@"status"] = @"ready";
    if (!includeMetadata || ![before isEqualToString:@"playing"]) return result;
    NSAppleEventDescriptor *track = mediaGet(application, target, 'pTrk', root, deadline);
    BOOL titleValid = NO, artistValid = NO, identityValid = NO, afterIdentityValid = NO;
    NSString *title = nil, *artist = nil;
    NSString *identity = nil, *afterIdentity = nil;
    DescType identityProperty = [player isEqualToString:@"appleMusic"] ? 'pPIS' : 'ID  ';
    if (track.descriptorType == typeObjectSpecifier) {
        identity = mediaText(mediaGet(application, target, identityProperty, track, deadline), &identityValid);
        title = mediaText(mediaGet(application, target, 'pnam', track, deadline), &titleValid);
        artist = mediaText(mediaGet(application, target, 'pArt', track, deadline), &artistValid);
    }
    // A returned current-track specifier can be dynamic. Re-read the current track's
    // stable ID, not just playback state, and withhold metadata if it changed.
    NSAppleEventDescriptor *afterTrack = mediaGet(application, target, 'pTrk', root, deadline);
    if (afterTrack.descriptorType == typeObjectSpecifier)
        afterIdentity = mediaText(mediaGet(application, target, identityProperty, afterTrack, deadline), &afterIdentityValid);
    NSString *after = mediaPlaybackState(mediaGet(application, target, 'pPlS', root, deadline));
    if (!after || application.isTerminated) {
        result[@"state"] = @"unknown";
        result[@"status"] = @"unavailable";
        return result;
    }
    result[@"state"] = after;
    if ([before isEqualToString:after] && identityValid && afterIdentityValid && identity.length
        && [identity isEqualToString:afterIdentity] && titleValid && artistValid) {
        if (title) result[@"title"] = title;
        if (artist) result[@"artist"] = artist;
    }
    return result;
}

NSDictionary<NSString *, id> *QSSetMediaPlaying(NSString *player, BOOL enabled) {
    NSString *bundle = [player isEqualToString:@"appleMusic"] ? @"com.apple.Music"
        : [player isEqualToString:@"spotify"] ? @"com.spotify.client" : nil;
    if (!bundle) return @{@"success": @NO, @"reason": @"invalidPlayer"};
    NSRunningApplication *application = nil;
    for (NSRunningApplication *candidate in QS_MEDIA_APPLICATIONS(bundle)) {
        if (!candidate.isTerminated && candidate.processIdentifier > 0 && [candidate.bundleIdentifier isEqualToString:bundle]) {
            application = candidate;
            break;
        }
    }
    if (!application) return @{@"success": @(!enabled), @"reason": @"notRunning"};
    NSAppleEventDescriptor *target = [NSAppleEventDescriptor descriptorWithProcessIdentifier:application.processIdentifier];
    AEEventClass suite = [player isEqualToString:@"appleMusic"] ? 'hook' : 'spfy';
    AEEventID command = enabled ? 'Play' : 'Paus';
    OSStatus authorization = AEDeterminePermissionToAutomateTarget(target.aeDesc, suite, command, true);
    if (authorization != noErr) return @{@"success": @NO, @"reason": @"permissionDenied"};
    if (application.isTerminated) return @{@"success": @(!enabled), @"reason": @"notRunning"};
    NSAppleEventDescriptor *event = [NSAppleEventDescriptor appleEventWithEventClass:suite
        eventID:command targetDescriptor:target returnID:kAutoGenerateReturnID transactionID:kAnyTransactionID];
    NSError *error = nil;
    NSAppleEventDescriptor *reply = QS_MEDIA_SEND(event, 2, &error);
    if (!reply || error || AEGetDescDataSize(reply.aeDesc) > 32768)
        return @{@"success": @NO, @"reason": @"unavailable"};
    NSAppleEventDescriptor *errorNumber = [reply paramDescriptorForKeyword:keyErrorNumber];
    if (errorNumber && errorNumber.int32Value != 0)
        return @{@"success": @NO, @"reason": @"unavailable"};
    return @{@"success": @YES};
}
