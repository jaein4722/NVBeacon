import Darwin
import Foundation
import Testing
@testable import NVBeacon

private func fixtureDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nvbeacon-process-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func waitForPID(at url: URL) async throws -> pid_t {
    for _ in 0..<200 {
        if let value = try? String(contentsOf: url, encoding: .utf8),
           let pid = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return pid
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw NSError(domain: "ProcessFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture process did not start"])
}

@Test func processRunnerDrainsLargeStdoutAndStderrBeforeExit() async throws {
    let result = try await ProcessCommandRunner().run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "/bin/dd if=/dev/zero bs=1048576 count=1 2>/dev/null; /bin/dd if=/dev/zero bs=1048576 count=1 1>&2 2>/dev/null"],
        timeout: 5
    )
    #expect(result.exitStatus == 0)
    #expect(result.standardOutput.utf8.count == 1_048_576)
    #expect(result.standardError.utf8.count == 1_048_576)
}

@Test func processRunnerRetainsNonzeroExitAndBothStreams() async throws {
    let result = try await ProcessCommandRunner().run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "printf 'output'; printf 'failure' >&2; exit 7"]
    )
    #expect(result.exitStatus == 7)
    #expect(result.standardOutput == "output")
    #expect(result.standardError == "failure")
}

@Test func cancellingACommandReapsAChildThatIgnoresTermination() async throws {
    let directory = try fixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let pidFile = directory.appendingPathComponent("pid")
    let task = Task {
        try await ProcessCommandRunner().run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; printf '%s' \"$$\" > \"$1\"; exec /bin/sleep 60", "fixture", pidFile.path], timeout: 10
        )
    }
    defer { task.cancel() }
    let pid = try await waitForPID(at: pidFile)
    let start = ContinuousClock.now
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(start.duration(to: .now) < .seconds(3))
    #expect(Darwin.kill(pid, 0) == -1)
}

@Test func timingOutACommandReapsItsChild() async throws {
    let directory = try fixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let pidFile = directory.appendingPathComponent("pid")
    let task = Task {
        try await ProcessCommandRunner().run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; printf '%s' \"$$\" > \"$1\"; exec /bin/sleep 60", "fixture", pidFile.path], timeout: 1
        )
    }
    defer { task.cancel() }
    let pid = try await waitForPID(at: pidFile)
    await #expect(throws: ProcessCommandRunner.RunError.timedOut) { try await task.value }
    #expect(Darwin.kill(pid, 0) == -1)
}

@Test func excessiveOutputStopsTheCommandWithBoundedCapture() async throws {
    await #expect(throws: ProcessCommandRunner.RunError.outputLimitExceeded(1024)) {
        try await ProcessCommandRunner().run(
            executable: URL(fileURLWithPath: "/bin/dd"),
            arguments: ["if=/dev/zero", "bs=1048576", "count=1"],
            timeout: 5, outputLimit: 1024
        )
    }
}

@Test func alreadyCancelledCommandsDoNotLaunch() async throws {
    let directory = try fixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let marker = directory.appendingPathComponent("launched")
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await ProcessCommandRunner().run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'launched' > \"$1\"", "fixture", marker.path]
        )
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!FileManager.default.fileExists(atPath: marker.path))
}

@Test func cancellationDoesNotWaitForAHelperHoldingOutputPipes() async throws {
    let directory = try fixtureDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let pidFile = directory.appendingPathComponent("pid")
    let task = Task {
        try await ProcessCommandRunner().run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "/bin/sleep 2 & printf '%s' \"$$\" > \"$1\"; printf 'ready'; wait", "fixture", pidFile.path],
            timeout: 5
        )
    }
    defer { task.cancel() }
    let pid = try await waitForPID(at: pidFile)
    let start = ContinuousClock.now
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(start.duration(to: .now) < .seconds(1))
    #expect(Darwin.kill(pid, 0) == -1)
}

@Test func fastCommandsCompleteWithoutContinuationRaces() async throws {
    for _ in 0..<20 {
        let output = try await ProcessCommandRunner().run(
            executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["fixture"], timeout: 2
        )
        #expect(output.standardOutput == "fixture\n")
    }
}

@Test func cancellationOfSSHCollectionDoesNotBecomeARetry() async {
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await SSHMetricsFetcher().fetchSummary(settings: AppSettings(sshTarget: "never-connect.example.invalid"))
    }
    await #expect(throws: CancellationError.self) { try await task.value }
}
