import Testing
import MDRKit
@testable import MDRSession

@Suite struct ChannelWatchdogTests {
    private let limit = Duration.seconds(20)
    private let start = ContinuousClock.now

    private func status(open: Bool = true, visible: Bool = false, busy: Bool = false) -> ChannelWatchdog.Status {
        .init(channelOpen: open, interfaceVisible: visible, busy: busy, lastActivity: start)
    }

    @Test func closesOnlyAfterTheIdleLimit() {
        var w = ChannelWatchdog()
        let r1 = w.shouldClose(status(), limit: limit, now: start + .seconds(19))
        #expect(!r1)
        #expect(w.closes == 0)
        let r2 = w.shouldClose(status(), limit: limit, now: start + .seconds(20))
        #expect(r2)
        #expect(w.closes == 1)
    }

    @Test func leavesTheChannelAloneWithInterfaceActionOrClosedChannel() {
        var w = ChannelWatchdog()
        let late = start + .seconds(60)
        let r3 = w.shouldClose(status(visible: true), limit: limit, now: late)
        #expect(!r3)
        let r4 = w.shouldClose(status(busy: true), limit: limit, now: late)
        #expect(!r4)
        let r5 = w.shouldClose(status(open: false), limit: limit, now: late)
        #expect(!r5)
        #expect(w.closes == 0)
    }

    /// O canal fica aberto sem ninguém agendar a liberação, e o `close` não volta.
    @Test func stuckChannelIsClosedEvenIfCloseHangsAndCanReopen() async throws {
        let fake = FakeHeadphones()
        var options = MDRSession.Options()
        options.ackTimeout = .milliseconds(60)
        options.responseTimeout = .milliseconds(250)
        let s = MDRSession(channel: fake, options: options)
        try await s.connect()
        #expect(await s.phase == .ready)
        await fake.configure { $0.closeHangs = true }

        var w = ChannelWatchdog()
        let open = await s.phase == .ready
        let due = w.shouldClose(status(open: open), limit: limit, now: start + limit)
        #expect(due)
        await s.forceDisconnect()
        #expect(await s.phase == .disconnected)
        for _ in 0..<100 where await fake.closeCalls == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await fake.closeCalls == 1)
        #expect(w.closes == 1)

        // Fechado, não dispara de novo.
        let stillOpen = await s.phase == .ready
        let r6 = w.shouldClose(status(open: stillOpen), limit: limit, now: start + .seconds(600))
        #expect(!r6)

        await fake.configure { $0.closeHangs = false }
        try await s.connect()
        #expect(await s.phase == .ready)
    }

    @Test func actionsWaitingForTheChannelFailInsteadOfHanging() async throws {
        let fake = FakeHeadphones()
        let s = MDRSession(channel: fake)
        try await s.connect()
        await fake.configure { $0.closeHangs = true; $0.neverAck = true }
        let pending = Task { try await s.send(.codec) }
        try await Task.sleep(for: .milliseconds(20))
        await s.forceDisconnect()
        await #expect(throws: MDRSessionError.self) { try await pending.value }
    }
}
