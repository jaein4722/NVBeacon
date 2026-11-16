import Foundation
import Testing
@testable import NVBeacon

@Test func turningAServerOffDropsItsReadingsFromTheTotals() {
    var server = ServerConfig(id: "one", sshTarget: "one.example.invalid")
    let snapshot = GPUSnapshot(takenAt: Date(), gpus: [
        GPUReading(index: 0, name: "GPU", uuid: "GPU-0", utilization: 90,
                   memoryUsedMB: 500, memoryTotalMB: 1000, temperatureCelsius: nil, processes: []),
    ])
    var state = ServerRuntimeState(server: server, snapshot: snapshot, lastErrorMessage: "timeout")

    server.name = "Renamed"
    state.update(to: server)
    #expect(state.snapshot == snapshot)
    #expect(state.server.name == "Renamed")

    server.isEnabled = false
    state.update(to: server)
    #expect(state.snapshot == nil)
    #expect(state.networkUsage == nil)
    #expect(state.lastErrorMessage == nil)
    #expect(!state.server.isEnabled)
}
