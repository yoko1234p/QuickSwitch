import Darwin
import Foundation

public struct CommandResult: Sendable {
  public let status: Int32
  public let output: String
  public var succeeded: Bool { status == 0 }
}

/// Foreground commands own a separate process group. Deadlines and cancellation
/// cover descendants and inherited pipes, as well as the direct child.
public final class CommandRunner: Sendable {
  private let outputLimit: Int
  private let capturesStandardError: Bool
  private let trimsOutput: Bool
  public init(
    maximumOutputBytes: Int = 65_536, capturesStandardError: Bool = true, trimsOutput: Bool = true
  ) {
    outputLimit = maximumOutputBytes
    self.capturesStandardError = capturesStandardError
    self.trimsOutput = trimsOutput
  }

  /// For legacy synchronous system adapters only; UI workflows should await run.
  @available(*, noasync, message: "Use await run for asynchronous workflows")
  public func runBlocking(_ executable: String, _ arguments: [String], timeout: TimeInterval = 12)
    -> CommandResult
  {
    Self.execute(
      executable, arguments, timeout: timeout, cancellation: Cancellation(),
      outputLimit: outputLimit, capturesStandardError: capturesStandardError,
      trimsOutput: trimsOutput)
  }
  public func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 12) async
    -> CommandResult
  {
    let cancellation = Cancellation()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
          continuation.resume(
            returning: Self.execute(
              executable, arguments, timeout: timeout, cancellation: cancellation,
              outputLimit: self.outputLimit, capturesStandardError: self.capturesStandardError,
              trimsOutput: self.trimsOutput))
        }
      }
    } onCancel: {
      cancellation.cancel()
    }
  }
  public func appleScript(_ script: String, timeout: TimeInterval = 12) async -> CommandResult {
    await run("/usr/bin/osascript", ["-e", script], timeout: timeout)
  }

  private static func execute(
    _ executable: String, _ arguments: [String], timeout: TimeInterval,
    cancellation: Cancellation, outputLimit: Int, capturesStandardError: Bool, trimsOutput: Bool
  ) -> CommandResult {
    guard executable.hasPrefix("/"), !executable.contains("\0"),
      arguments.allSatisfy({ !$0.contains("\0") }), timeout.isFinite, timeout > 0,
      (256...8_388_608).contains(outputLimit)
    else {
      return CommandResult(status: -1, output: "無效的指令或逾時設定")
    }
    if cancellation.isCancelled { return CommandResult(status: -3, output: "操作已取消") }
    do {
      let argv = try CStringVector([executable] + arguments)
      let envp = try CStringVector(
        ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }.sorted())
      let pipe = Pipe()
      defer {
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()
      }
      let reader = pipe.fileHandleForReading.fileDescriptor
      let writer = pipe.fileHandleForWriting.fileDescriptor
      guard reader >= 3, writer >= 3 else { throw POSIXError(.EBADF) }
      let flags = fcntl(reader, F_GETFL)
      guard flags >= 0, fcntl(reader, F_SETFL, flags | O_NONBLOCK) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      var actions: posix_spawn_file_actions_t?
      try check(posix_spawn_file_actions_init(&actions))
      defer { posix_spawn_file_actions_destroy(&actions) }
      try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
      try check(posix_spawn_file_actions_adddup2(&actions, writer, STDOUT_FILENO))
      if capturesStandardError {
        try check(posix_spawn_file_actions_adddup2(&actions, writer, STDERR_FILENO))
      } else {
        try check(
          posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0))
      }
      try check(posix_spawn_file_actions_addclose(&actions, reader))
      try check(posix_spawn_file_actions_addclose(&actions, writer))
      var attributes: posix_spawnattr_t?
      try check(posix_spawnattr_init(&attributes))
      defer { posix_spawnattr_destroy(&attributes) }
      var defaults = sigset_t()
      var mask = sigset_t()
      sigfillset(&defaults)
      sigdelset(&defaults, SIGKILL)
      sigdelset(&defaults, SIGSTOP)
      sigemptyset(&mask)
      try check(posix_spawnattr_setsigdefault(&attributes, &defaults))
      try check(posix_spawnattr_setsigmask(&attributes, &mask))
      // POSIX group 0 atomically creates a group whose ID is the child PID.
      try check(posix_spawnattr_setpgroup(&attributes, 0))
      try check(
        posix_spawnattr_setflags(
          &attributes,
          Int16(
            POSIX_SPAWN_SETPGROUP
              | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)))
      var pid: pid_t = 0
      try check(
        argv.withPointers { args in
          envp.withPointers { env in
            posix_spawn(&pid, executable, &actions, &attributes, args, env)
          }
        })
      try? pipe.fileHandleForWriting.close()
      var ownsChild = true
      defer {
        if ownsChild {
          // The child has not been reaped, so its PID cannot be reused
          // for an unrelated group while we remove surviving descendants.
          kill(-pid, SIGKILL)
          while waitpid(pid, nil, 0) < 0 && errno == EINTR {}
        }
      }
      let deadline = ProcessInfo.processInfo.systemUptime + timeout
      var output = Data()
      var buffer = [UInt8](repeating: 0, count: 8192)
      var failure: (status: Int32, message: String)?
      var terminateAt: TimeInterval?
      var killed = false
      func drain() {
        // A continuously writing descendant cannot starve deadline checks.
        for _ in 0..<16 {
          let count = Darwin.read(reader, &buffer, buffer.count)
          if count > 0 {
            let remaining = outputLimit - output.count
            output.append(contentsOf: buffer.prefix(min(count, remaining)))
            if count > remaining {
              failure = failure ?? (-4, "指令輸出超過 \(outputLimit) bytes，操作已停止")
              return
            }
          } else if count < 0, errno == EINTR {
            continue
          } else if count < 0, errno != EAGAIN && errno != EWOULDBLOCK {
            failure = failure ?? (-1, "未能讀取指令輸出")
            return
          } else {
            return
          }
        }
      }
      while true {
        drain()
        var info = siginfo_t()
        // WNOWAIT leaves an exited child reserved until descendant cleanup.
        let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
        if result < 0 {
          if errno == EINTR { continue }
          if errno == ECHILD { ownsChild = false }
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECHILD)
        }
        if info.si_pid == pid { break }
        let now = ProcessInfo.processInfo.systemUptime
        if failure == nil {
          if cancellation.isCancelled {
            failure = (-3, "操作已取消")
          } else if now >= deadline {
            failure = (-2, "操作逾時，已停止指令")
          }
        }
        if failure != nil, terminateAt == nil {
          kill(-pid, SIGTERM)
          terminateAt = now + 0.15
        }
        if let terminateAt, now >= terminateAt, !killed {
          kill(-pid, SIGKILL)
          killed = true
        }
        var event = pollfd(fd: reader, events: Int16(POLLIN), revents: 0)
        if poll(&event, 1, 15) < 0, errno != EINTR {
          failure = failure ?? (-1, "未能等候指令輸出")
        }
        // EOF/HUP is continuously ready; avoid spinning while a child
        // continues working with its output closed.
        if event.revents & Int16(POLLHUP) != 0 { Thread.sleep(forTimeInterval: 0.005) }
      }
      kill(-pid, SIGKILL)
      drain()
      var status: Int32 = 0
      var reaped: pid_t
      repeat { reaped = waitpid(pid, &status, 0) } while reaped < 0 && errno == EINTR
      guard reaped == pid else {
        if errno == ECHILD { ownsChild = false }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECHILD)
      }
      ownsChild = false
      if failure == nil, cancellation.isCancelled { failure = (-3, "操作已取消") }
      let decoded = String(decoding: output, as: UTF8.self)
      // Repairing one invalid byte can produce a three-byte replacement scalar.
      // Both raw transport data and returned UTF-8 text obey the same limit.
      if failure == nil, decoded.utf8.count > outputLimit {
        failure = (-4, "指令文字輸出超過 \(outputLimit) bytes，操作已停止")
      }
      if let failure {
        let suffix = "\n" + failure.message
        let prefix = boundedText(decoded, bytes: max(0, outputLimit - suffix.utf8.count))
        return CommandResult(
          status: failure.status,
          output: trimsOutput
            ? (prefix + suffix).trimmingCharacters(in: .whitespacesAndNewlines) : prefix + suffix)
      }
      let signal = status & 0x7f
      return CommandResult(
        status: signal == 0 ? (status >> 8) & 0xff : 128 + signal,
        output: trimsOutput ? decoded.trimmingCharacters(in: .whitespacesAndNewlines) : decoded)
    } catch { return CommandResult(status: -1, output: error.localizedDescription) }
  }

  private static func boundedText(_ text: String, bytes limit: Int) -> String {
    if text.utf8.count <= limit { return text }
    let scalars = text.unicodeScalars
    var index = scalars.startIndex
    var count = 0
    while index != scalars.endIndex {
      let value = scalars[index].value
      let width = value <= 0x7f ? 1 : value <= 0x7ff ? 2 : value <= 0xffff ? 3 : 4
      if count + width > limit { break }
      count += width
      index = scalars.index(after: index)
    }
    return String(scalars[..<index])
  }

  private static func check(_ status: Int32) throws {
    if status != 0 { throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO) }
  }
  private final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool {
      lock.lock()
      defer { lock.unlock() }
      return cancelled
    }
    func cancel() {
      lock.lock()
      cancelled = true
      lock.unlock()
    }
  }
  private final class CStringVector {
    private var values: [UnsafeMutablePointer<CChar>?] = []
    init(_ strings: [String]) throws {
      for string in strings {
        guard !string.contains("\0"), let pointer = strdup(string) else {
          for value in values { free(value) }
          values.removeAll()
          throw POSIXError(.EINVAL)
        }
        values.append(pointer)
      }
      values.append(nil)
    }
    deinit { for value in values { free(value) } }
    func withPointers<T>(_ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> T) -> T {
      values.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }
  }
}
