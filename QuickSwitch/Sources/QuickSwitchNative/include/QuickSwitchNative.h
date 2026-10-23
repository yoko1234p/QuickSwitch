#import <Foundation/Foundation.h>
FOUNDATION_EXPORT NSArray<NSDictionary<NSString *, id> *> *QSHeadphones(void);
FOUNDATION_EXPORT int QSSetHeadphoneConnection(NSString *address, BOOL connected);
FOUNDATION_EXPORT BOOL QSStartKeyboardLock(void);
FOUNDATION_EXPORT BOOL QSStartKeyboardLockWithTimeout(NSTimeInterval timeout);
FOUNDATION_EXPORT void QSStopKeyboardLock(void);
FOUNDATION_EXPORT BOOL QSKeyboardIsLocked(void);
FOUNDATION_EXPORT uint64_t QSKeyboardLockGeneration(void);
FOUNDATION_EXPORT NSTimeInterval QSKeyboardLockSecondsRemaining(void);
/// userInfo has stopped generation and reason; queued old notifications cannot end a newer session.
FOUNDATION_EXPORT NSNotificationName const QSKeyboardLockDidStopNotification;
FOUNDATION_EXPORT BOOL QSLockScreen(void);
FOUNDATION_EXPORT int QSDisplaySettingState(NSString *name);
FOUNDATION_EXPORT BOOL QSSetDisplaySetting(NSString *name, BOOL enabled);

FOUNDATION_EXPORT BOOL QSAutomationIsAuthorized(NSString *bundleIdentifier);
/// Bounded read-only AppleEvents to an existing Music/Spotify PID; never launches or prompts.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *QSReadMediaSnapshot(NSString *player, BOOL includeMetadata);
/// Explicit play/pause to an existing PID only. May request Automation permission; never launches a player.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *QSSetMediaPlaying(NSString *player, BOOL enabled);
/// Private OS capability, not an entitlement workaround. Unavailable/denied never means off.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *QSReadFocusState(void);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *QSSetFocusEnabled(BOOL enabled, NSTimeInterval duration);
