import Testing
import NIO
import NIOEmbedded
@preconcurrency import NIOSSH
import NVBeaconCore
@testable import NVBeaconMobile

@Test func commandCaptureKeepsBothStreamsAndNonzeroExit() throws {
    let channel = EmbeddedChannel()
    let result = channel.eventLoop.makePromise(of: RemoteCommandOutput.self)
    try channel.pipeline.syncOperations.addHandler(BoundedCommandHandler(result: result))
    try channel.writeInbound(SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(string: "GPU metrics"))))
    try channel.writeInbound(SSHChannelData(type: .stdErr, data: .byteBuffer(ByteBuffer(string: "diagnostic"))))
    channel.pipeline.fireUserInboundEventTriggered(SSHChannelRequestEvent.ExitStatus(exitStatus: 7))
    _ = try channel.finish()
    let output = try result.futureResult.wait()
    #expect(output.standardOutput == "GPU metrics")
    #expect(output.standardError == "diagnostic")
    #expect(output.exitStatus == 7)
}

@Test func commandCaptureRejectsDisconnectWithoutExitStatus() throws {
    let channel = EmbeddedChannel()
    let result = channel.eventLoop.makePromise(of: RemoteCommandOutput.self)
    try channel.pipeline.syncOperations.addHandler(BoundedCommandHandler(result: result))
    try channel.writeInbound(SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(string: "partial metrics"))))
    _ = try channel.finish()
    #expect(throws: MobileError.connectionClosed) { try result.futureResult.wait() }
}

@Test func commandCaptureCapsCombinedOutputBeforeBuffering() throws {
    let channel = EmbeddedChannel()
    let result = channel.eventLoop.makePromise(of: RemoteCommandOutput.self)
    try channel.pipeline.syncOperations.addHandler(BoundedCommandHandler(result: result, limit: 10))
    try channel.writeInbound(SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(string: "123456"))))
    try channel.writeInbound(SSHChannelData(type: .stdErr, data: .byteBuffer(ByteBuffer(string: "12345"))))
    #expect(throws: MobileError.outputTooLarge) { try result.futureResult.wait() }
    _ = try channel.finish(acceptAlreadyClosed: true)
}
