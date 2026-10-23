import Darwin
import Foundation
import XCTest

@testable import QuickSwitchCore

final class CommandRunnerTests: XCTestCase {
    private func assertTerminated(_ pid: pid_t, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<100 {
            if kill(pid, 0) < 0, errno == ESRCH { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Owned fixture descendant is still present: \(pid)", file: file, line: line)
    }
    func testArgumentsArePassedLiterallyAndFailuresKeepExitStatus() async {
        let value = "a space\n$(literal) `literal` \"quoted\""
        let result = await CommandRunner().run("/usr/bin/printf", ["%s", value])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, value)
        let failed = await CommandRunner().run("/bin/sh", ["-c", "printf out; printf err >&2; exit 7"])
        XCTAssertEqual(failed.status, 7)
        XCTAssertEqual(failed.output, "outerr")
    }
    func testBackgroundWriterDoesNotHoldPipeAfterParentExit() async throws {
        let began = ProcessInfo.processInfo.systemUptime
        let result = await CommandRunner().run("/bin/sh", ["-c", "sleep 10 & echo $!; exit 0"], timeout: 2)
        XCTAssertTrue(result.succeeded, result.output)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 1.5)
        let child = try XCTUnwrap(pid_t(result.output))
        try await assertTerminated(child)
    }
    func testDeadlineKillsTermIgnoringDescendants() async throws {
        let began = ProcessInfo.processInfo.systemUptime
        let result = await CommandRunner().run(
            "/bin/sh", ["-c", "trap '' TERM; sleep 10 & echo $!; wait"], timeout: 0.1)
        XCTAssertEqual(result.status, -2)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 2)
        let child = try XCTUnwrap(result.output.split(separator: "\n").first.flatMap { pid_t($0) })
        try await assertTerminated(child)
    }
    func testTaskCancellationReachesRunningGroup() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let receipt = folder.appendingPathComponent("child.pid")
        let task = Task {
            await CommandRunner().run(
                "/bin/sh",
                ["-c", "trap '' TERM; sleep 10 & echo $! > \"$1\"; wait", "fixture", receipt.path], timeout: 10)
        }
        defer { task.cancel() }
        var pid: pid_t?
        for _ in 0..<100 {
            pid = (try? String(contentsOf: receipt, encoding: .utf8))
                .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if pid != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let child = try XCTUnwrap(pid)
        let began = ProcessInfo.processInfo.systemUptime
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result.status, -3)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 2)
        try await assertTerminated(child)
    }
    func testOutputOverflowIsFailureInsteadOfTruncatedSuccess() async {
        let exact = await CommandRunner().run("/usr/bin/head", ["-c", "65536", "/dev/zero"])
        XCTAssertEqual(exact.status, 0)
        XCTAssertEqual(exact.output.utf8.count, 65536)
        let overflow = await CommandRunner().run("/usr/bin/head", ["-c", "1048576", "/dev/zero"])
        XCTAssertEqual(overflow.status, -4)
        XCTAssertLessThanOrEqual(overflow.output.utf8.count, 65536)
    }
    func testInvalidLaunchAndEarlyClosedOutputAreBounded() async {
        let runner = CommandRunner()
        for (path, arguments, timeout) in [
            ("relative", [""], 1.0), ("/usr/bin/printf", ["\0"], 1.0),
            ("/usr/bin/printf", ["a"], Double.nan), ("/missing-command-fixture", [], 1.0),
        ] {
            let result = await runner.run(path, arguments, timeout: timeout)
            XCTAssertFalse(result.succeeded)
        }
        let result = await runner.run("/bin/sh", ["-c", "exec 1>&-; exec 2>&-; sleep 0.1; exit 3"], timeout: 2)
        XCTAssertEqual(result.status, 3)
    }
    func testConcurrentCommandsHaveTheirOwnGroups() async {
        let results = await withTaskGroup(of: CommandResult.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    await CommandRunner().run(
                        "/bin/sh", ["-c", "printf '%s %s' \"$$\" \"$(ps -o pgid= -p $$)\""], timeout: 3)
                }
            }
            var values: [CommandResult] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(results.count, 16)
        var identifiers: Set<pid_t> = []
        for result in results {
            XCTAssertTrue(result.succeeded, result.output)
            let parts = result.output.split(whereSeparator: \.isWhitespace).compactMap { pid_t($0) }
            XCTAssertEqual(parts.count, 2)
            guard parts.count == 2 else { continue }
            XCTAssertEqual(parts[0], parts[1])
            XCTAssertNotEqual(parts[0], getpgrp())
            XCTAssertTrue(identifiers.insert(parts[0]).inserted)
        }
    }
}
