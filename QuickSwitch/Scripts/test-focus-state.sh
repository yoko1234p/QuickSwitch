#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FOCUS_FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/quickswitch-focus-state.XXXXXX")"
trap 'rm -rf "$FOCUS_FIXTURE"' EXIT
FOCUS_SOURCE_SUM="$(/usr/bin/shasum -a 256 "$TASK_ROOT/Sources/QuickSwitchNative/Focus.m")"
FOCUS_SOURCE_SHA="${FOCUS_SOURCE_SUM%% *}"
cat > "$FOCUS_FIXTURE/fixture.m" <<'OBJC'
// Compile the actual parsing helper into this translation unit; no framework service is invoked.
#import "Focus.m"
@interface StateFixture : NSObject
@property (nonatomic, assign) BOOL active;
@property (nonatomic, strong) id modes;
- (BOOL)isActive;
- (id)activeModeIdentifiers;
@end
@implementation StateFixture
- (BOOL)isActive { return self.active; }
- (id)activeModeIdentifiers { return self.modes; }
@end
@interface BadABIFixture : NSObject
- (NSInteger)isActive;
- (id)activeModeIdentifiers;
@end
@implementation BadABIFixture
- (NSInteger)isActive { return 1; }
- (id)activeModeIdentifiers { return @[]; }
@end
static int checks, failures;
static void check(BOOL value) { checks++; if (!value) failures++; }
int main(void) { @autoreleasepool {
    NSString *dnd = @"com.apple.donotdisturb.mode.default";
    StateFixture *state = [StateFixture new];
    state.active = NO; state.modes = nil;
    NSDictionary *result = QSFocusSnapshotForState(state, dnd);
    check([result[@"status"] isEqual:@"exact"] && ![result[@"dndEnabled"] boolValue]);
    state.active = YES; state.modes = @[dnd];
    result = QSFocusSnapshotForState(state, dnd);
    check([result[@"status"] isEqual:@"exact"] && [result[@"dndEnabled"] boolValue] && ![result[@"otherFocusActive"] boolValue]);
    state.modes = [NSSet setWithObject:@"fixture.other-focus"];
    result = QSFocusSnapshotForState(state, dnd);
    check([result[@"status"] isEqual:@"exact"] && ![result[@"dndEnabled"] boolValue] && [result[@"otherFocusActive"] boolValue]);
    state.modes = @[dnd, @"fixture.other-focus"];
    result = QSFocusSnapshotForState(state, dnd);
    check([result[@"dndEnabled"] boolValue] && [result[@"otherFocusActive"] boolValue]);
    for (id modes in @[@[], NSNull.null, @[@1], @[@""], @[@"x", NSNull.null]]) {
        state.active = YES; state.modes = modes;
        result = QSFocusSnapshotForState(state, dnd);
        check([result[@"status"] isEqual:@"unknown"] && result[@"dndEnabled"] == nil);
    }
    state.active = NO; state.modes = @[dnd];
    check([QSFocusSnapshotForState(state, dnd)[@"status"] isEqual:@"unknown"]);
    state.modes = @{};
    check([QSFocusSnapshotForState(state, dnd)[@"status"] isEqual:@"unknown"]);
    state.active = YES; state.modes = nil;
    check([QSFocusSnapshotForState(state, dnd)[@"status"] isEqual:@"unknown"]);
    state.modes = @[dnd, dnd];
    check([QSFocusSnapshotForState(state, dnd)[@"status"] isEqual:@"unknown"]);
    state.active = YES; state.modes = @[[ @"" stringByPaddingToLength:513 withString:@"a" startingAtIndex:0 ]];
    check([QSFocusSnapshotForState(state, dnd)[@"status"] isEqual:@"unknown"]);
    NSMutableArray *many = [NSMutableArray array];
    for (int i=0;i<33;i++) [many addObject:@"fixture.mode"];
    state.modes = many;
    check([QSFocusSnapshotForState(state, dnd)[@"status"] isEqual:@"unknown"]);
    check([QSFocusSnapshotForState([BadABIFixture new], dnd)[@"status"] isEqual:@"abiMismatch"]);
    printf("{\"assertions\":%d,\"failures\":%d,\"dndServiceCalls\":0,\"systemMutations\":0,\"sourceSHA256\":\"%s\"}\n", checks, failures, getenv("QS_FOCUS_SOURCE_SHA"));
} return failures ? 1 : 0; }
OBJC
xcrun clang -fobjc-arc -Werror -I "$TASK_ROOT/Sources/QuickSwitchNative" -I "$TASK_ROOT/Sources/QuickSwitchNative/include" \
    -framework Foundation "$FOCUS_FIXTURE/fixture.m" -o "$FOCUS_FIXTURE/fixture"
FOCUS_FINAL_SUM="$(/usr/bin/shasum -a 256 "$TASK_ROOT/Sources/QuickSwitchNative/Focus.m")"
[ "$FOCUS_SOURCE_SUM" = "$FOCUS_FINAL_SUM" ] || { echo 'Focus source changed during fixture compilation.' >&2; exit 3; }
QS_FOCUS_SOURCE_SHA="$FOCUS_SOURCE_SHA" "$FOCUS_FIXTURE/fixture"
