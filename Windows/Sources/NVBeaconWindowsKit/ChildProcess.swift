import Foundation
import WinSDK

/// Builds a `CreateProcessW` environment block: this process's environment plus
/// the given variables, sorted case-insensitively as Windows expects.
enum WindowsEnvironment {
    static func block(adding additions: [String: String]) -> [UInt16] {
        var merged: [String: (name: String, value: String)] = [:]
        for (name, value) in ProcessInfo.processInfo.environment { merged[name.uppercased()] = (name, value) }
        for (name, value) in additions { merged[name.uppercased()] = (name, value) }
        var block: [UInt16] = []
        for key in merged.keys.sorted() {
            let entry = merged[key]!
            block += Array("\(entry.name)=\(entry.value)".utf16) + [0]
        }
        return block + [0]
    }
}

/// A long-running console program without a console window, with a writable
/// standard input and standard output and error collected as they arrive.
///
/// Readers append to the buffers under `condition`; callers wait on it with
/// `wait(until:_:)` and consume what they have parsed.
final class ChildProcess: @unchecked Sendable {
    private let process: HANDLE
    private var input: HANDLE?
    private let condition = NSCondition()
    private var output: [UInt8] = []
    private var errorOutput: [UInt8] = []
    private var openPipes = 2
    private var exitCode: UInt32?

    private init(process: HANDLE, input: HANDLE) {
        self.process = process
        self.input = input
    }

    deinit {
        if let input { CloseHandle(input) }
        CloseHandle(process)
    }

    static func launch(executable: String, arguments: [String], environment: [String: String] = [:]) throws -> ChildProcess {
        var security = SECURITY_ATTRIBUTES(
            nLength: DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size), lpSecurityDescriptor: nil, bInheritHandle: true
        )
        var inRead: HANDLE?, inWrite: HANDLE?, outRead: HANDLE?, outWrite: HANDLE?, errRead: HANDLE?, errWrite: HANDLE?
        var info = PROCESS_INFORMATION()

        WindowsProcessRunner.launchLock.lock()
        let launched: Bool
        let launchError: DWORD
        do {
            defer { WindowsProcessRunner.launchLock.unlock() }
            guard CreatePipe(&inRead, &inWrite, &security, 0) else {
                throw ProcessRunError.launchFailed(executable: executable, code: GetLastError())
            }
            guard CreatePipe(&outRead, &outWrite, &security, 0), CreatePipe(&errRead, &errWrite, &security, 0) else {
                let code = GetLastError()
                for handle in [inRead, inWrite, outRead, outWrite] where handle != nil { CloseHandle(handle) }
                throw ProcessRunError.launchFailed(executable: executable, code: code)
            }
            // Only the child's ends are inherited.
            SetHandleInformation(inWrite, DWORD(HANDLE_FLAG_INHERIT), 0)
            SetHandleInformation(outRead, DWORD(HANDLE_FLAG_INHERIT), 0)
            SetHandleInformation(errRead, DWORD(HANDLE_FLAG_INHERIT), 0)

            var startup = STARTUPINFOW()
            startup.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
            startup.dwFlags = DWORD(STARTF_USESTDHANDLES)
            startup.hStdInput = inRead
            startup.hStdOutput = outWrite
            startup.hStdError = errWrite

            var commandLine = Array(WindowsCommandLine.build(executable: executable, arguments: arguments).utf16) + [0]
            var block = environment.isEmpty ? [] : WindowsEnvironment.block(adding: environment)
            launched = executable.withCString(encodedAs: UTF16.self) { application in
                block.withUnsafeMutableBufferPointer { environmentBlock in
                    CreateProcessW(application, &commandLine, nil, nil, true,
                                   DWORD(CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT),
                                   environmentBlock.isEmpty ? nil : environmentBlock.baseAddress, nil, &startup, &info)
                }
            }
            launchError = launched ? 0 : GetLastError()
            CloseHandle(inRead)
            CloseHandle(outWrite)
            CloseHandle(errWrite)
        }
        guard launched, let processHandle = info.hProcess, let inWrite else {
            CloseHandle(inWrite)
            CloseHandle(outRead)
            CloseHandle(errRead)
            throw ProcessRunError.launchFailed(executable: executable, code: launchError)
        }
        CloseHandle(info.hThread)

        let child = ChildProcess(process: processHandle, input: inWrite)
        child.startReader(outRead, isError: false)
        child.startReader(errRead, isError: true)
        return child
    }

    private func startReader(_ handle: HANDLE?, isError: Bool) {
        let bits = UInt(bitPattern: handle)
        Thread.detachNewThread { [self] in
            let handle = HANDLE(bitPattern: bits)
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                var read: DWORD = 0
                let ok = buffer.withUnsafeMutableBytes { ReadFile(handle, $0.baseAddress, DWORD($0.count), &read, nil) }
                guard ok, read > 0 else { break }
                condition.lock()
                if isError { errorOutput += buffer[0..<Int(read)] } else { output += buffer[0..<Int(read)] }
                condition.broadcast()
                condition.unlock()
            }
            CloseHandle(handle)
            condition.lock()
            openPipes -= 1
            let finished = openPipes == 0
            condition.unlock()
            if finished {
                // Both pipes closed: the process has exited or is about to.
                WaitForSingleObject(process, 5000)
                var code: DWORD = 0
                if !GetExitCodeProcess(process, &code) || code == DWORD(STILL_ACTIVE) { code = 255 }
                condition.lock()
                exitCode = code
                condition.broadcast()
                condition.unlock()
            }
        }
    }

    /// Writes all bytes to the child's standard input. False once the pipe is closed.
    func write(_ bytes: [UInt8]) -> Bool {
        condition.lock()
        let handle = input
        condition.unlock()
        guard let handle else { return false }
        var offset = 0
        while offset < bytes.count {
            var written: DWORD = 0
            let ok = bytes[offset...].withUnsafeBytes {
                WriteFile(handle, $0.baseAddress, DWORD($0.count), &written, nil)
            }
            guard ok, written > 0 else { return false }
            offset += Int(written)
        }
        return true
    }

    /// Closing standard input lets a remote `sh -s` exit, which ends ssh cleanly.
    func closeInput() {
        condition.lock()
        let handle = input
        input = nil
        condition.unlock()
        if let handle { CloseHandle(handle) }
    }

    func terminate() {
        TerminateProcess(process, 1)
    }

    /// Calls `body` with the buffers each time they change, until it returns a
    /// value or the deadline passes. `exitCode` is non-nil once the process ended
    /// and both pipes are drained.
    func wait<T>(until deadline: ContinuousClock.Instant,
                 _ body: (_ output: inout [UInt8], _ errorOutput: inout [UInt8], _ exitCode: UInt32?) -> T?) -> T? {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if let result = body(&output, &errorOutput, exitCode) { return result }
            let remaining = ContinuousClock.now.duration(to: deadline)
            if remaining <= .zero { return nil }
            let seconds = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
            _ = condition.wait(until: Date().addingTimeInterval(min(seconds, 1)))
        }
    }

    var hasExited: Bool {
        condition.lock()
        defer { condition.unlock() }
        return exitCode != nil
    }
}
