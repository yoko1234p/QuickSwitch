# MacProcessKit

Shared source for independently shipped QuickSwitch and SuperPilot bundles.
It links into each executable; there is no service, helper installation or
runtime dependency on the other app.

`CommandRunner.run` asynchronously runs a foreground command in its own process
group. `runBlocking` is reserved for short legacy synchronous adapters. Both
bound stdout/stderr, own the deadline, clean up descendants and retain the child
PID until cleanup prevents signalling a reused process group. Async task
cancellation reaches the owned group. Output overflow is a failure, not a
successful truncated response.

The default limit is64KiB; callers may explicitly choose256bytes...8MiB.
`capturesStandardError: false` keeps JSON helpers' stdout separate from stderr.
`trimsOutput: false` preserves exact leading/trailing whitespace and newlines,
for example when decoding a command's file path. The default remains trimmed
for existing callers. Raw mode keeps the same byte limits and failure behavior.
This runner is for foreground commands; surviving background children are
intentionally stopped when their direct foreground parent finishes.
Cleanup covers descendants that stay in that owned process group; deliberately
daemonized children are outside this guarantee. Cancellation does not roll back
system effects that the command has already performed.

```sh
cd Shared/MacProcessKit
swift test -j 4
```

The package tests exercise actual stderr backpressure, structured output,
larger bounded responses and invalid limits. QuickSwitch's existing integration
tests also run through the shared implementation, covering inherited pipes,
TERM-ignoring descendants, cancellation, exact output bounds and distinct
process groups. No fixture invokes an app/system toggle or user script.
Raw byte limits and returned UTF-8 limits both apply; replacement of invalid
bytes cannot turn an oversized repaired string into a successful response.
