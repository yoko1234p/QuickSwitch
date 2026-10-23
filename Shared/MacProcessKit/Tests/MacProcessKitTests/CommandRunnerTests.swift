import Darwin
import Foundation
import XCTest

@testable import MacProcessKit

final class CommandRunnerTests: XCTestCase {
  func testRawBlockingOutputPreservesWhitespaceAtTheByteLimit() {
    let text =
      String(repeating: " ", count: 64) + String(repeating: "a", count: 128)
      + String(repeating: " ", count: 64)
    let result = CommandRunner(maximumOutputBytes: 256, trimsOutput: false).runBlocking(
      "/usr/bin/printf", ["%s", text], timeout: 2)
    XCTAssertTrue(result.succeeded)
    XCTAssertEqual(result.output, text)
    XCTAssertEqual(result.output.utf8.count, 256)
  }

  func testRawAsyncOutputPreservesNewlinesAndTheDefaultRemainsTrimmed() async {
    let text = "  own path 尾空格  \n\n"
    let raw = await CommandRunner(trimsOutput: false).run(
      "/usr/bin/printf", ["%s", text], timeout: 2)
    let legacy = await CommandRunner().run("/usr/bin/printf", ["%s", text], timeout: 2)
    XCTAssertTrue(raw.succeeded)
    XCTAssertTrue(legacy.succeeded)
    XCTAssertEqual(raw.output, text)
    XCTAssertEqual(legacy.output, "own path 尾空格")
  }

  func testBlockingStderrFloodIsBoundedRatherThanWaitingOnAnUndrainedPipe() {
    let started = ProcessInfo.processInfo.systemUptime
    let result = CommandRunner(maximumOutputBytes: 1024).runBlocking(
      "/bin/sh", ["-c", "/usr/bin/head -c 1048576 /dev/zero >&2"], timeout: 1)
    XCTAssertEqual(result.status, -4)
    XCTAssertLessThanOrEqual(result.output.utf8.count, 1024)
    XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2)
  }

  func testUncapturedStderrCannotCorruptStructuredStdout() async throws {
    let result = await CommandRunner(capturesStandardError: false).run(
      "/bin/sh", ["-c", "printf '{\"fixture\":true}'; printf 'diagnostic' >&2"], timeout: 2)
    XCTAssertTrue(result.succeeded)
    let value = try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Bool]
    XCTAssertEqual(value, ["fixture": true])
  }

  func testLargerExplicitLimitSupportsBoundedSelectionOutput() async {
    let result = await CommandRunner(maximumOutputBytes: 1_048_576, capturesStandardError: false)
      .run(
        "/usr/bin/head", ["-c", "200000", "/dev/zero"], timeout: 2)
    XCTAssertTrue(result.succeeded)
    XCTAssertEqual(result.output.utf8.count, 200000)
  }

  func testInvalidLimitNeverSpawnsTheRequestedCommand() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let receipt = folder.appendingPathComponent("must-not-be-created")
    for limit in [0, 1, Int.max] {
      let result = await CommandRunner(maximumOutputBytes: limit).run(
        "/usr/bin/touch", [receipt.path])
      XCTAssertEqual(result.status, -1)
      XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.path))
    }
  }

  func testInvalidUTF8RepairIsAnOverflowRatherThanLargerSuccessfulText() async {
    let result = await CommandRunner(maximumOutputBytes: 256).run(
      "/usr/bin/printf", [String(repeating: "\\377", count: 256)], timeout: 2)
    XCTAssertEqual(result.status, -4)
    XCTAssertLessThanOrEqual(result.output.utf8.count, 256)
    XCTAssertTrue(result.output.contains("超過"))
  }

  func testOverflowPreservesCompleteScalarsAndTheFailureReason() async {
    let result = await CommandRunner(maximumOutputBytes: 256).run(
      "/usr/bin/printf", ["%s", String(repeating: "日", count: 200)], timeout: 2)
    XCTAssertEqual(result.status, -4)
    XCTAssertLessThanOrEqual(result.output.utf8.count, 256)
    XCTAssertFalse(result.output.contains("\u{fffd}"))
    XCTAssertTrue(result.output.hasSuffix("操作已停止"))
  }
}
