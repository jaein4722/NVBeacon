import Foundation
@preconcurrency import Citadel
@preconcurrency import Crypto
import NIO
@preconcurrency import NIOSSH
import NVBeaconCore

public struct TransferHostKey: Sendable {
    public let server: MobileServer
    let key: String
    public let fingerprint: String

    public static func lookup(_ server: MobileServer) async throws -> Self {
        guard !server.isEnabled, server.trustedHostKey == nil, server.transferSetupIssue == nil else {
            throw MacTransferImportError.changed
        }
        let transport = SSHTransport(server: server, credential: .init(), requestTimeout: .seconds(12))
        do { _ = try await transport.request(command: nil) }
        catch MobileError.hostKeyRequired(let key, let fingerprint) {
            return Self(server: server, key: key, fingerprint: fingerprint)
        }
        throw MobileError.connectionClosed
    }
}

private struct NoUserAuthentication: NIOSSHClientUserAuthenticationDelegate {
    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        nextChallengePromise.succeed(nil)
    }
}

struct PinnedHostValidator: NIOSSHClientServerAuthenticationDelegate {
    let expectedKey: String?
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise promise: EventLoopPromise<Void>) {
        let key = String(openSSHPublicKey: hostKey)
        let fingerprint = Self.fingerprint(key)
        guard let expectedKey else {
            promise.fail(MobileError.hostKeyRequired(key: key, fingerprint: fingerprint))
            return
        }
        guard key == expectedKey else {
            promise.fail(MobileError.hostKeyChanged(fingerprint: fingerprint))
            return
        }
        promise.succeed(())
    }

    static func fingerprint(_ key: String) -> String {
        let parts = key.split(separator: " ")
        guard parts.count >= 2, let bytes = Data(base64Encoded: String(parts[1])) else { return "Invalid key" }
        return "SHA256:" + Data(SHA256.hash(data: bytes)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
}

/// Each request owns a fresh connection, including the TCP channel during the SSH
/// handshake. Closing that channel unblocks command, timeout and cancellation paths.
public actor SSHTransport: RemoteCommandExecuting {
    private let server: MobileServer
    private let credential: MobileCredential
    private let requestTimeout: Duration
    private var channel: (any Channel)?
    private var operation: UUID?
    private var timedOut = false

    public init(server: MobileServer, credential: MobileCredential) {
        self.server = server
        self.credential = credential
        requestTimeout = .seconds(25)
    }

    init(server: MobileServer, credential: MobileCredential, requestTimeout: Duration) {
        self.server = server
        self.credential = credential
        self.requestTimeout = requestTimeout
    }

    nonisolated public static func validatePrivateKey(_ credential: MobileCredential) throws {
        _ = try ImportedSSHKey(credential.secret).authentication(username: "", passphrase: credential.passphrase)
    }

    public func execute(_ command: String) async throws -> RemoteCommandOutput {
        try await request(command: command)
    }

    fileprivate func request(command: String?) async throws -> RemoteCommandOutput {
        try Task.checkCancellation()
        let id = UUID()
        // Callers use a separate transport per refresh; reject overlapping requests.
        guard operation == nil else { throw MobileError.connectionClosed }
        operation = id
        timedOut = false
        let deadline = Task {
            try await Task.sleep(for: requestTimeout)
            await self.expire(id)
        }
        defer { deadline.cancel(); operation = nil }
        return try await withTaskCancellationHandler {
            do {
                let result = try await run(command)
                try Task.checkCancellation()
                await close()
                return result
            } catch {
                await close()
                if Task.isCancelled { throw CancellationError() }
                if timedOut { throw MobileError.timedOut }
                if error is SSHClientError || error is AuthenticationFailed { throw MobileError.authenticationFailed }
                throw error
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func expire(_ id: UUID) async {
        guard operation == id else { return }
        timedOut = true
        await close()
    }

    private func cancel(_ id: UUID) async {
        guard operation == id else { return }
        await close()
    }

    private func close() async {
        let connection = channel
        channel = nil
        try? await connection?.close()
    }

    private func run(_ command: String?) async throws -> RemoteCommandOutput {
        let server = try server.validated()
        let makeAuthentication: @Sendable () -> SSHAuthenticationMethod
        if command == nil {
            makeAuthentication = { .custom(NoUserAuthentication()) }
        } else {
            guard !credential.secret.isEmpty else { throw MobileError.missingCredential }
            switch server.authentication {
            case .passwordBased:
                let credential = credential
                makeAuthentication = { .passwordBased(username: server.username, password: credential.secret) }
            case .keyBased:
                makeAuthentication = try ImportedSSHKey(credential.secret)
                    .authentication(username: server.username, passphrase: credential.passphrase)
            }
        }
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let authenticated = loop.makePromise(of: Void.self)
        let validator = PinnedHostValidator(expectedKey: command == nil ? nil : server.pinnedHostKey)
        // Install the pipeline before connecting. Citadel 0.12.1's connect(on:)
        // performs synchronous pipeline mutation outside the channel event loop.
        // Owning setup here also prevents losing an early server banner and lets
        // cancellation close a channel that is still authenticating.
        let connection: any Channel
        do {
            connection = try await ClientBootstrap(group: loop)
            .channelInitializer { channel in
                do {
                    try channel.pipeline.syncOperations.addHandlers([
                        NIOSSHHandler(role: .client(.init(userAuthDelegate: makeAuthentication(), serverAuthDelegate: validator)),
                                      allocator: channel.allocator, inboundChildChannelInitializer: nil),
                        AuthenticationHandler(result: authenticated),
                    ])
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch { return channel.eventLoop.makeFailedFuture(error) }
            }
            .connectTimeout(.seconds(10))
            .connect(host: server.host, port: server.port).get()
        } catch {
            authenticated.fail(error)
            throw error
        }
        channel = connection
        try Task.checkCancellation()
        if timedOut { throw MobileError.timedOut }
        try await authenticated.futureResult.get()
        guard let command else { throw MobileError.connectionClosed }
        // Capture at the NIO channel boundary. An unbounded AsyncStream can queue
        // arbitrary output before an async consumer gets a chance to enforce a cap.
        let promise = connection.eventLoop.makePromise(of: RemoteCommandOutput.self)
        do {
            let child = try await connection.eventLoop.flatSubmit {
                connection.pipeline.handler(type: NIOSSHHandler.self).flatMap { handler in
                    let created = connection.eventLoop.makePromise(of: (any Channel).self)
                    handler.createChannel(created) { child, _ in
                        do {
                            try child.pipeline.syncOperations.addHandler(BoundedCommandHandler(result: promise))
                            return child.eventLoop.makeSucceededVoidFuture()
                        } catch { return child.eventLoop.makeFailedFuture(error) }
                    }
                    return created.futureResult
                }
            }.get()
            try await child.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true))
            let output = try await promise.futureResult.get()
            if timedOut { throw MobileError.timedOut }
            return output
        } catch {
            promise.fail(error)
            throw error
        }
    }
}

private final class AuthenticationHandler: ChannelInboundHandler {
    typealias InboundIn = Any
    private let result: EventLoopPromise<Void>
    private var completed = false
    init(result: EventLoopPromise<Void>) { self.result = result }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent, !completed {
            completed = true
            result.succeed(())
        } else { context.fireUserInboundEventTriggered(event) }
    }
    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        if !completed { completed = true; result.fail(error) }
        context.close(promise: nil)
    }
    func channelInactive(context: ChannelHandlerContext) {
        if !completed { completed = true; result.fail(MobileError.connectionClosed) }
        context.fireChannelInactive()
    }
}

final class BoundedCommandHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    private let result: EventLoopPromise<RemoteCommandOutput>
    private var stdout = Data()
    private var stderr = Data()
    private var status: Int32?
    private var completed = false
    private let limit: Int

    init(result: EventLoopPromise<RemoteCommandOutput>, limit: Int = 2_097_152) {
        self.result = result
        self.limit = limit
    }

    func handlerAdded(context: ChannelHandlerContext) {
        // OpenSSH may send EOF before exit-status. Keep the child channel alive
        // for that final status rather than treating EOF as a full disconnect.
        let channel = context.channel
        channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { [result] error in
            result.fail(error)
            channel.close(promise: nil)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !completed else { return }
        let data = unwrapInboundIn(data)
        guard case .byteBuffer(let bytes) = data.data else { return }
        guard stdout.count + stderr.count + bytes.readableBytes <= limit else {
            fail(MobileError.outputTooLarge, context: context)
            return
        }
        switch data.type {
        case .channel: stdout.append(contentsOf: bytes.readableBytesView)
        case .stdErr: stderr.append(contentsOf: bytes.readableBytesView)
        default: break
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let exit = event as? SSHChannelRequestEvent.ExitStatus {
            status = Int32(clamping: exit.exitStatus)
        } else if event is ChannelFailureEvent {
            fail(MobileError.commandFailed(-1, "The SSH server refused command execution."), context: context)
        } else { context.fireUserInboundEventTriggered(event) }
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish()
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) { finish() }

    func errorCaught(context: ChannelHandlerContext, error: any Error) { fail(error, context: context) }

    private func finish() {
        guard !completed else { return }
        completed = true
        guard let status else { result.fail(MobileError.connectionClosed); return }
        result.succeed(.init(standardOutput: String(decoding: stdout, as: UTF8.self),
                             standardError: String(decoding: stderr, as: UTF8.self), exitStatus: status))
    }

    private func fail(_ error: any Error, context: ChannelHandlerContext) {
        guard !completed else { return }
        completed = true
        result.fail(error)
        context.close(promise: nil)
    }
}
