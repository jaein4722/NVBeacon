import Foundation
import Testing
import NIO
@preconcurrency import NIOSSH
import Crypto
import Citadel
@testable import NVBeaconMobile

private final class FixtureAuthentication: NIOSSHServerUserAuthenticationDelegate {
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = [.password, .publicKey]
    func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        if case .password(let value) = request.request, value.password == "fixture-only", request.username == "fixture" {
            responsePromise.succeed(.success)
        } else if case .publicKey = request.request, request.username == "fixture" {
            responsePromise.succeed(.success)
        } else { responsePromise.succeed(.failure) }
    }
}

private final class FixtureCommand: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard let request = event as? SSHChannelRequestEvent.ExecRequest else { return }
        let channel = context.channel
        if request.wantReply { channel.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil) }
        if request.command == "hang" { return }
        channel.write(SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(string: "fixture-stdout"))), promise: nil)
        channel.writeAndFlush(SSHChannelData(type: .stdErr, data: .byteBuffer(ByteBuffer(string: "fixture-stderr"))), promise: nil)
        channel.close(mode: .output).flatMap {
            channel.triggerUserOutboundEvent(SSHChannelRequestEvent.ExitStatus(exitStatus: 7))
        }.whenComplete { _ in channel.close(promise: nil) }
    }
    func errorCaught(context: ChannelHandlerContext, error: any Error) { context.close(promise: nil) }
}

private func withSSHFixture(_ body: (MobileServer) async throws -> Void) async throws {
    let key = Curve25519.Signing.PrivateKey()
    let hostKey = NIOSSHPrivateKey(ed25519Key: key)
    let listener = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        .childChannelInitializer { channel in
            do {
                try channel.pipeline.syncOperations.addHandler(NIOSSHHandler(
                    role: .server(.init(hostKeys: [NIOSSHPrivateKey(ed25519Key: key)], userAuthDelegate: FixtureAuthentication())),
                    allocator: channel.allocator,
                    inboundChildChannelInitializer: { child, _ in
                        do {
                            try child.pipeline.syncOperations.addHandler(FixtureCommand())
                            return child.eventLoop.makeSucceededVoidFuture()
                        } catch { return child.eventLoop.makeFailedFuture(error) }
                    }))
                return channel.eventLoop.makeSucceededVoidFuture()
            } catch { return channel.eventLoop.makeFailedFuture(error) }
        }.bind(host: "127.0.0.1", port: 0).get()
    do {
        var server = MobileServer()
        server.host = "127.0.0.1"
        server.port = try #require(listener.localAddress?.port)
        server.username = "fixture"
        server.authentication = .passwordBased
        server.trustedHostKey = String(openSSHPublicKey: hostKey.publicKey)
        server.trustedEndpoint = server.endpoint
        try await body(server)
        try await listener.close()
    } catch {
        try? await listener.close()
        throw error
    }
}

@Test func realSSHHandshakeAndExecPreserveOutputAndExit() async throws {
    try await withSSHFixture { server in
        let transport = SSHTransport(server: server, credential: .init(secret: "fixture-only"))
        let output = try await transport.execute("fixture")
        #expect(output.standardOutput == "fixture-stdout")
        #expect(output.standardError == "fixture-stderr")
        #expect(output.exitStatus == 7)
    }
}

@Test func importedEd25519KeyAuthenticatesOverSSH() async throws {
    try await withSSHFixture { original in
        var server = original
        server.authentication = .keyBased
        let key = Curve25519.Signing.PrivateKey()
        let credential = MobileCredential(secret: key.makeSSHRepresentation())
        try SSHTransport.validatePrivateKey(credential)
        let transport = SSHTransport(server: server, credential: credential)
        let output = try await transport.execute("fixture")
        #expect(output.standardOutput == "fixture-stdout")
        #expect(output.exitStatus == 7)
    }
}

@Test func realSSHHandshakeRejectsUntrustedAndChangedKeys() async throws {
    try await withSSHFixture { trusted in
        var server = trusted
        server.trustedHostKey = nil
        let untrusted = SSHTransport(server: server, credential: .init(secret: "fixture-only"))
        do { _ = try await untrusted.execute("fixture"); Issue.record("Unknown key was accepted") }
        catch MobileError.hostKeyRequired(let key, let fingerprint) {
            #expect(key == trusted.trustedHostKey)
            #expect(fingerprint.hasPrefix("SHA256:"))
        }
        server.trustedHostKey = "different-host-key"
        let changed = SSHTransport(server: server, credential: .init(secret: "fixture-only"))
        do { _ = try await changed.execute("fixture"); Issue.record("Changed key was accepted") }
        catch MobileError.hostKeyChanged { }
    }
}

@Test func realSSHCommandCancellationClosesConnection() async throws {
    try await withSSHFixture { server in
        let transport = SSHTransport(server: server, credential: .init(secret: "fixture-only"))
        let task = Task { try await transport.execute("hang") }
        try await Task.sleep(for: .milliseconds(200))
        let cancelledAt = ContinuousClock.now
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled SSH command completed") }
        catch { #expect(error is CancellationError) }
        #expect(cancelledAt.duration(to: .now) < .seconds(2))
    }
}

@Test func realSSHCommandDeadlineClosesHungConnection() async throws {
    try await withSSHFixture { server in
        let transport = SSHTransport(server: server, credential: .init(secret: "fixture-only"), requestTimeout: .milliseconds(150))
        let startedAt = ContinuousClock.now
        do { _ = try await transport.execute("hang"); Issue.record("Hung SSH command completed") }
        catch { #expect(error as? MobileError == .timedOut) }
        #expect(startedAt.duration(to: .now) < .seconds(2))
    }
}
