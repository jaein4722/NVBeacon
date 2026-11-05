import Foundation
import Testing
@testable import NVBeaconTransfer

@Test func bulkPayloadBindsCredentialTypesAndRejectsUnreferencedSecrets() throws {
    let key = UUID()
    let secret = TransferCredential(kind: "passwordBased", secret: "fixture-only")
    func server() -> TransferServer {
        TransferServer(id: UUID(), name: "test", host: "example.invalid", username: "demo", port: 2222,
                       authentication: "passwordBased", gpuCommand: "gpu", memoryCommand: "memory",
                       hostCommand: "host", credentialID: key, setupIssue: nil)
    }
    let profiles = [server(), server()]
    let id = UUID()
    let data = try TransferBatch(id: id, servers: profiles, credentials: [key: secret]).encoded()
    let received = try TransferBatch.decode(data)
    #expect(received.id == id)
    #expect(received.credentials.count == 1)
    #expect(received.servers.map(\.credentialID) == [key, key])
    for credentials in [[:], [key: TransferCredential(kind: "keyBased", secret: "fixture")], [key: secret, UUID(): secret]] {
        #expect(throws: TransferPayloadError.self) { try TransferBatch(id: id, servers: profiles, credentials: credentials).encoded() }
    }
}
