import Foundation
import Network
import Testing
@testable import NVBeaconTransfer

@Test func invitationRejectsMalformedExpiredAndUnboundedInput() throws {
    let invitation = PairingInvitation(lifetime: 120)
    let original = try PairingInvitation(text: invitation.text)
    #expect(original.id == invitation.id)
    #expect(original.secret.count == 32)
    #expect(!original.serviceName.contains(original.secret.base64EncodedString()))
    #expect(throws: PairingError.expired) { try PairingInvitation(text: PairingInvitation(lifetime: -1).text) }
    #expect(throws: PairingError.invalidInvitation) { try PairingInvitation(text: "https://example.invalid") }
    #expect(throws: PairingError.invalidInvitation) { try PairingInvitation(text: String(repeating: "x", count: 4096)) }
}

@Test @MainActor func transferRequiresMatchingCodeApprovalAndReceipt() async throws {
    let sender = PairingSender(lifetime: 10, advertise: false)
    var senderCode: String?
    let qr = try await sender.start { senderCode = $0 }
    let port = try #require(sender.port)
    let receiver = PairingReceiver(endpoint: .hostPort(host: "127.0.0.1", port: port))
    defer { receiver.cancel(); sender.cancel() }
    let payload = Data(repeating: 0x42, count: 140_000)
    await #expect(throws: PairingError.invalidState) { try await sender.send(payload) }
    var receiverCode: String?
    let receive = Task { try await receiver.receive(invitation: qr) { receiverCode = $0 } }
    for _ in 0..<250 where receiverCode == nil {
        try await Task.sleep(for: .milliseconds(20))
    }
    let code = try #require(senderCode)
    #expect(code.count == 6)
    #expect(receiverCode == code)
    var acknowledged = false
    let send = Task { try await sender.send(payload); acknowledged = true }
    #expect(try await receive.value == payload)
    #expect(!acknowledged)
    try await receiver.acknowledge()
    try await send.value
    #expect(acknowledged)
    await #expect(throws: PairingError.invalidState) { try await sender.send(payload) }
    await #expect(throws: PairingError.invalidState) { try await receiver.acknowledge() }
    await #expect(throws: PairingError.invalidState) { try await receiver.receive(invitation: qr) { _ in } }
}

@Test @MainActor func wrongSecretCannotReachApproval() async throws {
    let sender = PairingSender(lifetime: 3, advertise: false)
    var offered = false
    let qr = try await sender.start { _ in offered = true }
    var fields = qr.components(separatedBy: ":")
    fields[4] = Data(repeating: 0xBC, count: 32).base64EncodedString()
    let port = try #require(sender.port)
    let receiver = PairingReceiver(endpoint: .hostPort(host: "127.0.0.1", port: port))
    defer { receiver.cancel(); sender.cancel() }
    await #expect(throws: (any Error).self) {
        try await receiver.receive(invitation: fields.joined(separator: ":")) { _ in Issue.record("Unverified sender") }
    }
    #expect(!offered)
    await #expect(throws: PairingError.invalidState) { try await sender.send(Data([1])) }
}

@Test @MainActor func cancelWhileListeningInvalidatesInvitation() async throws {
    let sender = PairingSender(lifetime: 5, advertise: false)
    _ = try await sender.start { _ in Issue.record("Unexpected pairing") }
    sender.cancel()
    await #expect(throws: PairingError.invalidState) { try await sender.start { _ in } }
    #expect(sender.port == nil)
}

@Test @MainActor func expiredListenerReleasesItsPortAndReportsFailure() async throws {
    let sender = PairingSender(lifetime: 1, advertise: false)
    var reason: PairingError?
    sender.onFailure = { reason = $0 }
    _ = try await sender.start { _ in Issue.record("Unexpected receiver") }
    for _ in 0..<100 where reason == nil {
        try await Task.sleep(for: .milliseconds(30))
    }
    #expect(reason == .expired)
    #expect(sender.port == nil)
    await #expect(throws: PairingError.invalidState) { try await sender.send(Data([1])) }
}

// Run explicitly on a local-network-capable host to exercise the very same
// Bonjour endpoint scanned by the camera. The default tests stay loopback-only.
@Test(.enabled(if: ProcessInfo.processInfo.environment["NVBEACON_TEST_BONJOUR"] == "1"))
@MainActor func bonjourPairingDeliversAcknowledgedSyntheticPayload() async throws {
    let sender = PairingSender(lifetime: 15, advertise: true)
    let receiver = PairingReceiver()
    defer { receiver.cancel(); sender.cancel() }
    var macCode: String?
    var phoneCode: String?
    let qr = try await sender.start { macCode = $0 }
    let payload = Data("synthetic Bonjour fixture".utf8)
    let received = Task {
        let bytes = try await receiver.receive(invitation: qr) { phoneCode = $0 }
        try await receiver.acknowledge()
        return bytes
    }
    for _ in 0..<300 where phoneCode == nil {
        try await Task.sleep(for: .milliseconds(30))
    }
    #expect(try #require(macCode) == #require(phoneCode))
    try await sender.send(payload)
    #expect(try await received.value == payload)
}
