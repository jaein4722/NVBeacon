import Dispatch
import Foundation
import WinSDK

public struct ProcessOutput: Sendable, Equatable {
    public let standardOutput: [UInt8]
    public let standardError: [UInt8]
    public let exitCode: UInt32
}

public enum ProcessRunError: Error, Equatable, Sendable {
    case launchFailed(executable: String, code: UInt32)
    case timedOut(seconds: Int)
    case outputLimitExceeded(bytes: Int)
}

/// Runs a console program without a console window, with captured output,
/// a hard timeout, an output cap and cancellation that terminates the process.
///
/// Foundation's `Process` is not used because it cannot pass `CREATE_NO_WINDOW`,
/// so every poll from the tray app would flash a console window.
public enum WindowsProcessRunner {
    /// Handle inheritance is process-wide: while one launch has inheritable pipe
    /// ends open, a concurrent launch would inherit them and keep the pipes open.
    private static let launchLock = NSLock()

    public static func run(
        executable: String,
        arguments: [String],
        timeout: Duration = .seconds(15),
        outputLimit: Int = 8 * 1024 * 1024
    ) async throws -> ProcessOutput {
        let control = ProcessControl()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Thread.detachNewThread {
                    continuation.resume(with: Result {
                        try runBlocking(executable: executable, arguments: arguments,
                                        timeout: timeout, outputLimit: outputLimit, control: control)
                    })
                }
            }
        } onCancel: {
            control.cancel()
        }
    }

    private static func runBlocking(
        executable: String, arguments: [String], timeout: Duration, outputLimit: Int, control: ProcessControl
    ) throws -> ProcessOutput {
        if control.isCancelled { throw CancellationError() }

        var security = SECURITY_ATTRIBUTES(
            nLength: DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size), lpSecurityDescriptor: nil, bInheritHandle: true
        )
        var outRead: HANDLE?, outWrite: HANDLE?, errRead: HANDLE?, errWrite: HANDLE?
        var process = PROCESS_INFORMATION()

        launchLock.lock()
        let launched: Bool
        let launchError: DWORD
        do {
            defer { launchLock.unlock() }
            guard CreatePipe(&outRead, &outWrite, &security, 0), CreatePipe(&errRead, &errWrite, &security, 0) else {
                throw ProcessRunError.launchFailed(executable: executable, code: GetLastError())
            }
            SetHandleInformation(outRead, DWORD(HANDLE_FLAG_INHERIT), 0)
            SetHandleInformation(errRead, DWORD(HANDLE_FLAG_INHERIT), 0)
            let nullInput = "NUL".withCString(encodedAs: UTF16.self) {
                CreateFileW($0, DWORD(GENERIC_READ), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE),
                            &security, DWORD(OPEN_EXISTING), 0, nil)
            }
            defer { if nullInput != INVALID_HANDLE_VALUE { CloseHandle(nullInput) } }

            var startup = STARTUPINFOW()
            startup.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
            startup.dwFlags = DWORD(STARTF_USESTDHANDLES)
            startup.hStdInput = nullInput
            startup.hStdOutput = outWrite
            startup.hStdError = errWrite

            var commandLine = Array(WindowsCommandLine.build(executable: executable, arguments: arguments).utf16) + [0]
            launched = executable.withCString(encodedAs: UTF16.self) { application in
                CreateProcessW(application, &commandLine, nil, nil, true,
                               DWORD(CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT), nil, nil, &startup, &process)
            }
            launchError = launched ? 0 : GetLastError()
            // The child owns its copies now; ours must close or ReadFile never sees EOF.
            CloseHandle(outWrite)
            CloseHandle(errWrite)
        }
        guard launched else {
            CloseHandle(outRead)
            CloseHandle(errRead)
            throw ProcessRunError.launchFailed(executable: executable, code: launchError)
        }
        CloseHandle(process.hThread)
        control.attach(process.hProcess)
        defer {
            control.detach()
            CloseHandle(process.hProcess)
        }

        let collector = OutputCollector(limit: outputLimit) { control.terminate() }
        let readers = DispatchGroup()
        for (handle, isError) in [(outRead, false), (errRead, true)] {
            let pipe = UInt(bitPattern: handle)
            readers.enter()
            DispatchQueue.global().async {
                defer { readers.leave() }
                let handle = HANDLE(bitPattern: pipe)
                defer { CloseHandle(handle) }
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    var read: DWORD = 0
                    let ok = buffer.withUnsafeMutableBytes {
                        ReadFile(handle, $0.baseAddress, DWORD($0.count), &read, nil)
                    }
                    guard ok, read > 0 else { break }
                    guard collector.append(buffer[0..<Int(read)], isError: isError) else { break }
                }
            }
        }

        let milliseconds = timeout.components.seconds * 1000 + timeout.components.attoseconds / 1_000_000_000_000_000
        let waited = WaitForSingleObject(process.hProcess, DWORD(clamping: milliseconds))
        let timedOut = waited == DWORD(WAIT_TIMEOUT)
        if timedOut {
            control.terminate()
            WaitForSingleObject(process.hProcess, INFINITE)
        }
        readers.wait()

        if control.isCancelled { throw CancellationError() }
        if timedOut { throw ProcessRunError.timedOut(seconds: Int(timeout.components.seconds)) }
        if collector.exceeded { throw ProcessRunError.outputLimitExceeded(bytes: outputLimit) }

        var exitCode: DWORD = 0
        GetExitCodeProcess(process.hProcess, &exitCode)
        let (standardOutput, standardError) = collector.result
        return ProcessOutput(standardOutput: standardOutput, standardError: standardError, exitCode: exitCode)
    }
}

/// Lets cancellation terminate a process that another thread is waiting on.
private final class ProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: HANDLE?
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func attach(_ handle: HANDLE?) {
        lock.withLock {
            self.handle = handle
            if cancelled { TerminateProcess(handle, 1) }
        }
    }

    func detach() { lock.withLock { handle = nil } }

    func cancel() {
        lock.withLock {
            cancelled = true
            if let handle { TerminateProcess(handle, 1) }
        }
    }

    func terminate() {
        lock.withLock { if let handle { TerminateProcess(handle, 1) } }
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private let onExceeded: () -> Void
    private var output: [UInt8] = []
    private var error: [UInt8] = []
    private var overLimit = false

    var exceeded: Bool { lock.withLock { overLimit } }

    init(limit: Int, onExceeded: @escaping () -> Void) {
        self.limit = limit
        self.onExceeded = onExceeded
    }

    /// Returns false once the combined output passes the limit.
    func append(_ bytes: ArraySlice<UInt8>, isError: Bool) -> Bool {
        let stop: Bool = lock.withLock {
            if isError { error += bytes } else { output += bytes }
            if output.count + error.count > limit { overLimit = true }
            return overLimit
        }
        if stop { onExceeded() }
        return !stop
    }

    var result: ([UInt8], [UInt8]) { lock.withLock { (output, error) } }
}
