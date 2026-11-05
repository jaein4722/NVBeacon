import CryptoKit
import Foundation
import Network
import Security

public enum PairingError: LocalizedError, Equatable {
    case invalidInvitation, expired, closed, invalidState, invalidMessage, unavailable, authentication

    case localNetworkDenied, macNotFound

    public var errorDescription: String? {
        switch self {
        case .invalidInvitation: "Scan a valid NVBeacon pairing QR code."
        case .expired: "The pairing session timed out. Generate a new QR code."
        case .closed: "The pairing connection closed."
        case .invalidState: "Generate a new QR code to start another transfer."
        case .invalidMessage: "The pairing data is invalid or too large."
        case .unavailable: "Could not connect. Check local network permissions and that both devices are on the same network."
        case .authentication: "The pairing session could not be authenticated."
        case .localNetworkDenied: "Allow NVBeacon to access the local network in Settings."
        case .macNotFound: "Show a pairing code on your Mac and connect both devices to the same local network."
        }
    }
}

struct PairingInvitation {
    // RFC 7905: authenticate the QR PSK and negotiate fresh ephemeral EC keys.
    // Check the selected suite again when obtaining the TLS channel binding.
    static let cipherSuite = tls_ciphersuite_t(rawValue: 0xCCAC)!
    static let serviceType = "_nvbeacon-xfer._tcp"
    let id: UUID
    let secret: Data
    let expiry: Int64

    init(lifetime: Int) {
        id = UUID()
        secret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        expiry = Int64(Date().timeIntervalSince1970) + Int64(lifetime)
    }

    var serviceName: String { "nvb-" + id.uuidString }
    var text: String {
        // An opaque QR payload, never an HTTP URL or a Bonjour TXT record.
        ["NVBeacon-Pair", "1", id.uuidString, String(expiry), secret.base64EncodedString()].joined(separator: ":")
    }

    init(text: String) throws {
        guard text.utf8.count <= 160 else { throw PairingError.invalidInvitation }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0] == "NVBeacon-Pair", parts[1] == "1",
              let id = UUID(uuidString: String(parts[2])), let expiry = Int64(parts[3]),
              let secret = Data(base64Encoded: String(parts[4])), secret.count == 32
        else { throw PairingError.invalidInvitation }
        let now = Int64(Date().timeIntervalSince1970)
        guard expiry > now else { throw PairingError.expired }
        guard expiry <= now + 300 else { throw PairingError.invalidInvitation }
        self.id = id
        self.expiry = expiry
        self.secret = secret
    }

    func parameters() -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        let psk = secret.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data(id.uuidString.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(options, psk as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(options, Self.cipherSuite)
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_tls_resumption_enabled(options, false)
        sec_protocol_options_set_tls_tickets_enabled(options, false)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.prohibitedInterfaceTypes = [.cellular]
        return parameters
    }
}

@MainActor private final class ResultSignal<T: Sendable> {
    private var result: Result<T, Error>?
    private var continuation: CheckedContinuation<T, Error>?

    func finish(_ result: Result<T, Error>) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(with: result)
        continuation = nil
    }

    func value() async throws -> T {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
}

private enum Frame: UInt8 {
    case hello = 1, welcome, payload, receipt
}

@MainActor private final class PairingConnection {
    private let connection: NWConnection
    private let ready = ResultSignal<Void>()
    private var established = false
    private var pendingFailure: ((PairingError) -> Void)?
    private(set) var error: PairingError?
    var onClose: ((PairingError) -> Void)?

    init(_ connection: NWConnection) { self.connection = connection }

    func restartIfWaiting() {
        if !established, case .waiting = connection.state { connection.restart() }
    }

    func establish(checkLocalAccess: Bool = false) async throws {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                if checkLocalAccess && !self.established {
                    switch state {
                    case .waiting(let error), .failed(let error):
                        let denied: Bool
                        if case .dns(let code) = error, Int(code) == kDNSServiceErr_PolicyDenied { denied = true }
                        else { denied = self.connection.currentPath?.unsatisfiedReason == .localNetworkDenied }
                        if denied { self.close(.localNetworkDenied); return }
                    default: break
                    }
                }
                switch state {
                case .ready:
                    self.established = true
                    self.ready.finish(.success(()))
                case .waiting(.tls), .failed(.tls): self.close(.authentication)
                case .failed: self.close(.unavailable)
                case .cancelled: self.close(.closed)
                default: break
                }
            }
        }
        connection.start(queue: .main)
        try await ready.value()
    }

    func close(_ reason: PairingError = .closed) {
        guard error == nil else { return }
        error = reason
        ready.finish(.failure(reason))
        pendingFailure?(reason)
        pendingFailure = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        let notify = onClose
        onClose = nil
        notify?(reason)
    }

    // Bind the QR secret to this specific TLS connection. Separate role labels
    // prevent a reflected proof from authenticating the opposite peer.
    private func boundMaterial(_ label: String) throws -> Data {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata
        else { throw PairingError.authentication }
        guard sec_protocol_metadata_get_negotiated_tls_ciphersuite(metadata.securityProtocolMetadata) == PairingInvitation.cipherSuite
        else { throw PairingError.authentication }
        let exporterLabel = "EXPORTER-NVBeacon-pairing-v1"
        guard let secret = sec_protocol_metadata_create_secret(metadata.securityProtocolMetadata,
                exporterLabel.utf8.count, exporterLabel, 32)
        else { throw PairingError.authentication }
        return Data(secret as DispatchData) + Data(label.utf8)
    }

    func proof(_ label: String, invitation: PairingInvitation) throws -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: try boundMaterial(label), using: SymmetricKey(data: invitation.secret)))
    }

    func verifies(_ proof: Data, role: String, invitation: PairingInvitation) throws -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: try boundMaterial(role),
                                                using: SymmetricKey(data: invitation.secret))
    }

    func comparisonCode(_ invitation: PairingInvitation) throws -> String {
        let prefix = try proof("compare", invitation: invitation).prefix(4)
        let value = prefix.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return String(format: "%06u", value % 1_000_000)
    }

    func write(_ type: Frame, _ data: Data, final: Bool = false) async throws {
        if let error { throw error }
        guard data.count <= TransferBatch.maximumBytes else { throw PairingError.invalidMessage }
        let count = UInt32(data.count).bigEndian
        var frame = Data([type.rawValue])
        withUnsafeBytes(of: count) { frame.append(contentsOf: $0) }
        frame.append(data)
        let sent = ResultSignal<Void>()
        pendingFailure = { sent.finish(.failure($0)) }
        defer { pendingFailure = nil }
        connection.send(content: frame, contentContext: final ? .finalMessage : .defaultMessage,
                        isComplete: true, completion: .contentProcessed { error in
            MainActor.assumeIsolated { sent.finish(error == nil ? .success(()) : .failure(PairingError.closed)) }
        })
        try await sent.value()
    }

    func read(_ type: Frame, length: ClosedRange<Int>) async throws -> Data {
        let header = try await readBytes(5)
        let count = header.dropFirst().reduce(0) { ($0 << 8) | Int($1) }
        guard header.first == type.rawValue, length.contains(count) else { throw PairingError.invalidMessage }
        return try await readBytes(count)
    }

    private func readBytes(_ count: Int) async throws -> Data {
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            if let error { throw error }
            let next = ResultSignal<Data>()
            pendingFailure = { next.finish(.failure($0)) }
            defer { pendingFailure = nil }
            connection.receive(minimumIncompleteLength: 1, maximumLength: min(65_536, count - result.count)) { data, _, _, error in
                MainActor.assumeIsolated {
                    if let data, !data.isEmpty, error == nil { next.finish(.success(data)) }
                    else { next.finish(.failure(PairingError.closed)) }
                }
            }
            result.append(try await next.value())
        }
        return result
    }
}

@MainActor public final class PairingSender {
    public var onFailure: (@MainActor (PairingError) -> Void)?
    private let lifetime: Int
    private let advertise: Bool
    private var listener: NWListener?
    private var deadline: Task<Void, Never>?
    private var attempt: PairingConnection?
    private var paired: PairingConnection?
    private let started = ResultSignal<Void>()
    private var used = false
    private var sending = false
    private var ended = false
    var port: NWEndpoint.Port? { listener?.port }

    public init() { lifetime = 180; advertise = true }
    init(lifetime: Int, advertise: Bool) { self.lifetime = lifetime; self.advertise = advertise }

    public func start(onCode: @escaping @MainActor (String) -> Void) async throws -> String {
        guard !used, !ended else { throw PairingError.invalidState }
        used = true
        let invitation = PairingInvitation(lifetime: lifetime)
        let parameters = invitation.parameters()
        if !advertise { parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any) }
        let listener = try NWListener(using: parameters)
        self.listener = listener
        if advertise {
            var service = NWListener.Service(name: invitation.serviceName, type: PairingInvitation.serviceType, domain: "local.")
            service.noAutoRename = true
            listener.service = service
        }
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .ready: self?.started.finish(.success(()))
                case .failed: self?.stop(.unavailable, notify: true)
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                guard let self, !self.ended, self.paired == nil, self.attempt == nil else { connection.cancel(); return }
                let link = PairingConnection(connection)
                self.attempt = link
                Task { await self.authenticate(link, invitation: invitation, onCode: onCode) }
            }
        }
        deadline = Task { [weak self, lifetime] in
            do { try await Task.sleep(for: .seconds(lifetime)) } catch { return }
            self?.stop(.expired, notify: true)
        }
        listener.start(queue: .main)
        return try await withTaskCancellationHandler {
            try await started.value()
            try Task.checkCancellation()
            return invitation.text
        } onCancel: { Task { @MainActor in self.cancel() } }
    }

    private func authenticate(_ link: PairingConnection, invitation: PairingInvitation, onCode: @MainActor (String) -> Void) async {
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            link.close(.expired)
        }
        defer { timeout.cancel() }
        do {
            try await link.establish()
            let proof = try await link.read(.hello, length: 32...32)
            guard try link.verifies(proof, role: "receiver", invitation: invitation), !ended else { throw PairingError.authentication }
            try await link.write(.welcome, link.proof("sender", invitation: invitation))
            let code = try link.comparisonCode(invitation)
            guard !ended, attempt === link, link.error == nil else { throw PairingError.closed }
            attempt = nil
            paired = link
            releaseListener()
            link.onClose = { [weak self] error in self?.stop(error, notify: true) }
            onCode(code)
        } catch {
            link.close()
            if attempt === link { attempt = nil }
        }
    }

    public func send(_ data: Data) async throws {
        guard !ended, !sending, let paired else { throw PairingError.invalidState }
        guard (1...TransferBatch.maximumBytes).contains(data.count) else { throw PairingError.invalidMessage }
        sending = true
        defer { stop(.closed, notify: false) }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await paired.write(.payload, data)
            let receipt = try await paired.read(.receipt, length: 32...32)
            guard receipt == Data(SHA256.hash(data: data)) else { throw PairingError.invalidMessage }
        } onCancel: { Task { @MainActor in self.cancel() } }
    }

    public func cancel() { stop(.closed, notify: false) }

    private func releaseListener() {
        listener?.newConnectionHandler = nil
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
    }

    private func stop(_ reason: PairingError, notify: Bool) {
        guard !ended else { return }
        ended = true
        deadline?.cancel()
        deadline = nil
        releaseListener()
        started.finish(.failure(reason))
        attempt?.close(reason)
        paired?.onClose = nil
        paired?.close(reason)
        attempt = nil
        paired = nil
        if notify { onFailure?(reason) }
        onFailure = nil
    }
}

@MainActor public final class PairingReceiver {
    private let endpointOverride: NWEndpoint?
    private var link: PairingConnection?
    private var receipt: Data?
    private var deadline: Task<Void, Never>?
    private var used = false

    public init() { endpointOverride = nil }
    init(endpoint: NWEndpoint) { endpointOverride = endpoint }

    public func resumeConnectionIfWaiting() { link?.restartIfWaiting() }

    public func receive(invitation text: String, onCode: @escaping @MainActor (String) -> Void) async throws -> Data {
        guard !used else { throw PairingError.invalidState }
        used = true
        let invitation = try PairingInvitation(text: text)
        let endpoint = endpointOverride ?? .service(name: invitation.serviceName, type: PairingInvitation.serviceType,
                                                    domain: "local.", interface: nil)
        let link = PairingConnection(NWConnection(to: endpoint, using: invitation.parameters()))
        self.link = link
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(1, invitation.expiry - Int64(Date().timeIntervalSince1970)))) }
            catch { return }
            self?.stop(.expired)
        }
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                let connecting = Task {
                    try await Task.sleep(for: .seconds(15))
                    link.close(.macNotFound)
                }
                defer { connecting.cancel() }
                do { try await link.establish(checkLocalAccess: true) }
                catch PairingError.unavailable { throw PairingError.macNotFound }
                connecting.cancel()
                let handshake = Task {
                    try await Task.sleep(for: .seconds(15))
                    link.close(.closed)
                }
                defer { handshake.cancel() }
                try await link.write(.hello, link.proof("receiver", invitation: invitation))
                let proof = try await link.read(.welcome, length: 32...32)
                guard try link.verifies(proof, role: "sender", invitation: invitation) else { throw PairingError.authentication }
                handshake.cancel()
                onCode(try link.comparisonCode(invitation))
                let payload = try await link.read(.payload, length: 1...TransferBatch.maximumBytes)
                try Task.checkCancellation()
                receipt = Data(SHA256.hash(data: payload))
                return payload
            } catch { stop(.closed); throw error }
        } onCancel: { Task { @MainActor in self.cancel() } }
    }

    /// Call only once the batch has been durably saved.
    public func acknowledge() async throws {
        guard let link, let receipt else { throw PairingError.invalidState }
        self.receipt = nil
        defer { stop(.closed) }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await link.write(.receipt, receipt, final: true)
        } onCancel: { Task { @MainActor in self.cancel() } }
    }

    public func cancel() { used = true; stop(.closed) }

    private func stop(_ reason: PairingError) {
        deadline?.cancel()
        deadline = nil
        link?.close(reason)
        link = nil
        receipt = nil
    }
}
