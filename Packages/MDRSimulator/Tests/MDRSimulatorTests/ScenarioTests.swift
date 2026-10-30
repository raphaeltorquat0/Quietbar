import Foundation
import MDRKit
import MDRSession
import Testing
@testable import MDRSimulator

@Suite struct ScenarioTests {
    private let step = Duration.milliseconds(15)

    @Test func buttonChangesTheSoundMode() async throws {
        let (t, s) = try await connected(Profiles.wfC700N)
        let modes = Modes()
        let watch = Task { for await snap in await s.snapshots() { if let m = snap.state.noiseControl?.soundMode { modes.add(m) } } }
        #expect(await Scenario.buttonMode.run(on: t, step: step) == .ran)
        #expect(await eventually(s) { $0.noiseControl?.soundMode == .noiseCanceling })
        watch.cancel()
        #expect(modes.contains(.ambient) && modes.contains(.off))
    }

    @Test func buttonDoesNotApplyWithoutSoundMode() async throws {
        let t = VirtualTransport(profile: Profiles.wfC500)
        #expect(await Scenario.buttonMode.run(on: t, step: step) != .ran)
    }

    @Test(arguments: ["wh1000xm5", "linkbudsclip"])
    func batteryReachesTheAlertLevel(_ id: String) async throws {
        let (t, s) = try await connected(try #require(Profiles.find(id)))
        await Scenario.batteryDrain.run(on: t, step: step)
        #expect(await eventually(s) { $0.primaryBattery?.level == 5 })
    }

    @Test func earbudLeavesAndReturnsToTheCase() async throws {
        let (t, s) = try await connected(Profiles.wf1000xm6)
        #expect(await eventually(s) { $0.batteryLR != nil })
        let full = await s.state.batteryLR
        let run = Task { await Scenario.earbudCase.run(on: t, step: .milliseconds(120)) }
        #expect(await eventually(s) { $0.batteryLR?.right.level == 0 })
        #expect(await s.state.primaryBattery?.level == full!.left.level)
        #expect(await run.value == .ran)
        #expect(await eventually(s) { $0.batteryLR == full })
    }

    @Test func earbudCaseDoesNotApplyToOverEar() async throws {
        let t = VirtualTransport(profile: Profiles.wh1000xm6)
        #expect(await Scenario.earbudCase.run(on: t, step: step) != .ran)
    }

    @Test func reconnectsAfterTheDeviceDisappears() async throws {
        let (t, s) = try await connected(Profiles.wh1000xm6)
        await Scenario.reconnect.run(on: t, step: step) { event in
            if event == .connectionLost {
                // A sessão percebe o fechamento do canal por conta própria, sem depender do host.
                while await s.phase != .disconnected { try? await Task.sleep(for: .milliseconds(2)) }
                await #expect(throws: (any Error).self) { try await s.connect() }
            }
            if event == .connectionRestored { try? await s.connect() }
        }
        #expect(await s.phase == .ready)
        #expect(await s.state.modelName == "WH-1000XM6")
    }

    @Test func survivesSleepAndWake() async throws {
        let (t, s) = try await connected(Profiles.linkBudsS)
        await Scenario.sleepWake.run(on: t, step: step) { event in
            if event == .willSleep { await s.disconnect() }
            if event == .didWake { try? await s.connect() }
        }
        #expect(await s.phase == .ready)
    }

    @Test func slowDeviceStillAnswersAndSilentDeviceTimesOut() async throws {
        let (t, s) = try await connected(Profiles.wh1000xm5)
        await t.configure { $0.latency = .milliseconds(30) }
        try await s.send(.codec)
        await t.configure { $0.unresponsive = true }
        await #expect(throws: MDRSessionError.self) { try await s.send(.codec) }
        await t.configure {
            $0.unresponsive = false
            $0.latency = .zero
        }
        try await s.send(.codec)
        await Scenario.slowResponse.run(on: t, step: step)
        try await s.send(.codec)
    }

    @Test func corruptFrameIsDroppedAndTheSessionGoesOn() async throws {
        let (t, s) = try await connected(Profiles.wh1000xm5)
        await Scenario.corruptFrame.run(on: t, step: step)
        #expect(await eventually(s) { $0.primaryBattery?.level == 33 })
        #expect(await s.phase == .ready)
        try await s.send(.codec)
    }

    @Test func scenarioNamesAreStable() {
        #expect(Scenario.allCases.map(\.rawValue) == ["botao", "bateria", "estojo", "reconexao", "sono", "lento", "corrompido"])
    }
}

final class Modes: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: Set<SoundMode> = []
    func add(_ m: SoundMode) { lock.withLock { _ = seen.insert(m) } }
    func contains(_ m: SoundMode) -> Bool { lock.withLock { seen.contains(m) } }
}
