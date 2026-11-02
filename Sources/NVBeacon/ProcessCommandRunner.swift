import Darwin
import Foundation

/// macOS process backend. No process/file-descriptor API belongs in NVBeaconCore.
struct ProcessCommandRunner: Sendable {
    typealias Output = RemoteCommandOutput

    enum RunError: Error, Equatable, Sendable {
        case timedOut
        case outputLimitExceeded(Int)
    }

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 15,
        outputLimit: Int = 8 * 1024 * 1024
    ) async throws -> Output {
        try Task.checkCancellation()
        let execution = Execution(executable: executable, arguments: arguments,
                                  environment: environment, timeout: timeout,
                                  outputLimit: outputLimit)
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                execution.start(continuation)
            }
        } onCancel: {
            execution.cancel()
        }
        try Task.checkCancellation()
        return result
    }
}

/// Data can arrive on two FileHandle callback queues. Only the buffers use a
/// lock; all launch, termination and continuation state lives on one queue.
private final class ProcessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var stdout = Data()
    private var stderr = Data()
    private var exceeded = false
    private var closed = false

    init(limit: Int) { self.limit = max(0, limit) }

    func append(_ data: Data, isStandardError: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, !exceeded else { return false }
        let remaining = limit - stdout.count - stderr.count
        let accepted = data.prefix(max(0, remaining))
        if isStandardError { stderr.append(accepted) } else { stdout.append(accepted) }
        if data.count > remaining {
            exceeded = true
            return true
        }
        return false
    }

    func finish() -> (Data, Data) {
        lock.lock()
        defer { lock.unlock() }
        closed = true
        return (stdout, stderr)
    }
}

private final class Execution: @unchecked Sendable {
    private let queue = DispatchQueue(label: "NVBeacon.command", qos: .utility)
    private let process = Process()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let buffer: ProcessOutputBuffer
    private let timeout: TimeInterval
    private let outputLimit: Int
    private var continuation: CheckedContinuation<ProcessCommandRunner.Output, any Error>?
    private var timeoutWork: DispatchWorkItem?
    private var killWork: DispatchWorkItem?
    private var launched = false
    private var exited = false
    private var stdoutEnded = false
    private var stderrEnded = false
    private var cancelled = false
    private var finished = false
    private var failure: (any Error)?

    init(executable: URL, arguments: [String], environment: [String: String]?,
         timeout: TimeInterval, outputLimit: Int) {
        self.timeout = max(0.001, timeout)
        self.outputLimit = max(0, outputLimit)
        buffer = ProcessOutputBuffer(limit: outputLimit)
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
    }

    func start(_ continuation: CheckedContinuation<ProcessCommandRunner.Output, any Error>) {
        queue.async { [self] in
            self.continuation = continuation
            if self.cancelled {
                self.failure = CancellationError()
                self.finish()
                return
            }
            self.installReader(self.stdout.fileHandleForReading, isStandardError: false)
            self.installReader(self.stderr.fileHandleForReading, isStandardError: true)
            self.process.terminationHandler = { _ in
                self.queue.async {
                    self.exited = true
                    self.finishIfReady()
                }
            }
            do {
                try self.process.run()
                self.launched = true
                // EOF must not depend on these parent-side write descriptors.
                try? self.stdout.fileHandleForWriting.close()
                try? self.stderr.fileHandleForWriting.close()
                let work = DispatchWorkItem { [weak self] in
                    self?.stop(with: ProcessCommandRunner.RunError.timedOut)
                }
                self.timeoutWork = work
                self.queue.asyncAfter(deadline: .now() + self.timeout, execute: work)
            } catch {
                self.failure = error
                self.finish()
            }
        }
    }

    func cancel() {
        queue.async {
            self.cancelled = true
            self.stop(with: CancellationError())
        }
    }

    private func installReader(_ handle: FileHandle, isStandardError: Bool) {
        handle.readabilityHandler = { handle in
            do {
                let data = try handle.read(upToCount: 64 * 1024) ?? Data()
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    self.queue.async {
                        if isStandardError { self.stderrEnded = true } else { self.stdoutEnded = true }
                        self.finishIfReady()
                    }
                } else if self.buffer.append(data, isStandardError: isStandardError) {
                    self.queue.async {
                        self.stop(with: ProcessCommandRunner.RunError.outputLimitExceeded(self.outputLimit))
                    }
                }
            } catch {
                self.queue.async { self.stop(with: error) }
            }
        }
    }

    private func stop(with error: any Error) {
        guard !finished else { return }
        if failure == nil { failure = error }
        guard launched else {
            if continuation != nil { finish() }
            return
        }
        if exited {
            finish()
            return
        }
        guard killWork == nil else { return }
        if process.isRunning { process.terminate() }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.finished, !self.exited, self.process.isRunning else { return }
            Darwin.kill(self.process.processIdentifier, SIGKILL)
        }
        killWork = work
        queue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func finishIfReady() {
        guard !finished, launched, exited else { return }
        // On error, only the owned child must be reaped. A helper inheriting a
        // pipe cannot hold up cancellation. Success still requires both EOFs.
        if failure != nil || (stdoutEnded && stderrEnded) { finish() }
    }

    private func finish() {
        guard !finished, let continuation else { return }
        finished = true
        self.continuation = nil
        timeoutWork?.cancel()
        killWork?.cancel()
        process.terminationHandler = nil
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        try? stdout.fileHandleForReading.close()
        try? stderr.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        let (output, errors) = buffer.finish()
        if let failure {
            continuation.resume(throwing: failure)
        } else {
            continuation.resume(returning: .init(
                standardOutput: String(decoding: output, as: UTF8.self),
                standardError: String(decoding: errors, as: UTF8.self),
                exitStatus: process.terminationStatus
            ))
        }
    }
}
