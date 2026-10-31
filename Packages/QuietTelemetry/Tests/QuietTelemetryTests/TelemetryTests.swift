import Foundation
import MDRSimulator
import Testing
@testable import QuietTelemetry

private let start = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21, 14:13 UTC
private let utc = TimeZone(identifier: "UTC")!
private let endpoint = URL(string: "https://example.invalid/m")

private final class Box: @unchecked Sendable {
    var now = start
    var saved: Data?
    var family: String? = "WH-1000XM5"
    var automation = false
    var requests: [URLRequest] = []
    var status = 204
    var failing = false

    func advance(days: Int, hours: Int = 0) { now += TimeInterval(days * 86400 + hours * 3600) }
}

@MainActor
private func make(_ b: Box, enabled: Bool = true) -> TelemetryRecorder {
    let r = TelemetryRecorder(load: { b.saved }, save: { b.saved = $0 }, context: {
        TelemetryContext(appVersion: "1.4.0", macOSMajor: 27, arch: "arm64", deviceModelFamily: b.family, automationEnabled: b.automation, trialDay: nil)
    }, now: { b.now }, timeZone: utc)
    r.setEnabled(enabled)
    return r
}

@MainActor
private func send(_ r: TelemetryRecorder, _ b: Box, to url: URL? = endpoint) async {
    await r.sendIfDue(endpoint: url) { request in
        b.requests.append(request)
        if b.failing { throw URLError(.notConnectedToInternet) }
        return b.status
    }
}

private func object(_ data: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] }

@MainActor @Suite struct TelemetryRecorderTests {
    private let b = Box()

    @Test func aggregatesTheDayBySource() {
        let r = make(b)
        r.recordModeChange(.panel)
        r.recordModeChange(.panel)
        r.recordModeChange(.externalChange)
        r.recordModeChange(.hotkey)
        r.recordTrigger(.call)
        r.recordTrigger(.shortcut)
        r.recordOverride()
        r.recordPanelOpen()
        let json = object(r.nextPayload().json)
        #expect(json["manualModeChanges"] as? Int == 4)
        #expect(json["activeDay"] as? Bool == true)
        #expect(json["panelOpens"] as? Int == 1)
        let sources = json["modeChangesBySource"] as? [String: Int]
        #expect(sources == ["panel": 2, "controlCenter": 0, "hotkey": 1, "intent": 0, "externalChange": 1])
        let automation = json["automation"] as? [String: Any]
        #expect(automation?["triggersFired"] as? [String: Int] == ["call": 1, "focus": 0, "app": 0, "wifi": 0, "shortcut": 1])
        #expect(automation?["overridesManual"] as? Int == 1)
    }

    @Test func dayWithoutEventsIsNotActive() {
        let r = make(b)
        r.recordAppRunning()
        #expect(object(r.nextPayload().json)["activeDay"] as? Bool == false)
    }

    @Test func countersAboveFiftyBecomeFifty() {
        let r = make(b)
        for _ in 0..<80 { r.recordPanelOpen(); r.recordModeChange(.panel) }
        for _ in 0..<40 { r.recordModeChange(.hotkey) }
        for _ in 0..<50 { r.recordTrigger(.app) }
        let json = object(r.nextPayload().json)
        #expect(json["panelOpens"] as? Int == 50)
        #expect(json["manualModeChanges"] as? Int == 50) // 120 no total
        #expect((json["modeChangesBySource"] as? [String: Int])?["hotkey"] == 40)
        #expect(((json["automation"] as? [String: Any])?["triggersFired"] as? [String: Int])?["app"] == 50)
    }

    @Test func idRotatesAfterNinetyDaysAndNotBefore() {
        let r = make(b)
        let first = object(r.nextPayload().json)["installId"] as? String
        b.advance(days: 89)
        #expect(object(r.nextPayload().json)["installId"] as? String == first)
        b.advance(days: 1)
        let second = object(r.nextPayload().json)["installId"] as? String
        #expect(second != first)
        #expect(UUID(uuidString: second ?? "") != nil)
    }

    @Test func offNothingIsCountedStoredOrSent() async {
        let r = make(b, enabled: false)
        r.recordModeChange(.panel)
        r.recordPanelOpen()
        b.advance(days: 1)
        await send(r, b)
        #expect(b.requests.isEmpty)
        #expect(r.state.days.isEmpty)
        #expect(r.state.installId == nil)
    }

    @Test func noURLNoSend() async {
        let r = make(b)
        r.recordPanelOpen()
        b.advance(days: 1)
        await send(r, b, to: nil)
        #expect(b.requests.isEmpty)
        #expect(r.state.days.count == 1)
    }

    @Test func onlyHTTPSCounts() {
        #expect(TelemetryRecorder.endpoint("https://a.lambda-url.us-east-1.on.aws/") != nil)
        #expect(TelemetryRecorder.endpoint("http://example.com") == nil)
        #expect(TelemetryRecorder.endpoint("") == nil)
        #expect(TelemetryRecorder.endpoint(nil) == nil)
    }

    @Test func shownJSONIsExactlyTheSentBody() async throws {
        let r = make(b)
        r.recordModeChange(.intent)
        b.advance(days: 1)
        let shown = r.nextPayload()
        #expect(!shown.isPartial && !shown.isExample)
        await send(r, b)
        #expect(b.requests.first?.httpBody == shown.json)
    }

    @Test func todayIsNotSentUntilItCloses() async {
        let r = make(b)
        r.recordPanelOpen()
        #expect(r.nextPayload().isPartial)
        await send(r, b)
        #expect(b.requests.isEmpty)
    }

    @Test func atMostOnePacketPerDay() async {
        let r = make(b)
        r.recordPanelOpen()
        b.advance(days: 1)
        r.recordPanelOpen()
        b.advance(days: 1)
        await send(r, b)
        await send(r, b)
        #expect(b.requests.count == 1)
        b.advance(days: 0, hours: 7) // passou da espera de nova tentativa, mas é o mesmo dia
        await send(r, b)
        #expect(b.requests.count == 1)
        b.advance(days: 1)
        await send(r, b)
        #expect(b.requests.count == 2)
    }

    @Test func failureWaitsAndThenTriesAgain() async {
        let r = make(b)
        r.recordPanelOpen()
        b.advance(days: 1)
        b.failing = true
        await send(r, b)
        await send(r, b)
        #expect(b.requests.count == 1)
        b.failing = false
        b.advance(days: 0, hours: 6)
        await send(r, b)
        #expect(b.requests.count == 2)
        #expect(r.state.days.isEmpty)
    }

    @Test func unsentPacketIsDroppedAfterThreeDays() async {
        let r = make(b)
        r.recordPanelOpen()
        b.advance(days: 3)
        #expect(!r.nextPayload().isPartial)
        b.advance(days: 1)
        await send(r, b)
        #expect(b.requests.isEmpty)
        #expect(r.state.days.isEmpty)
    }

    @Test func rejectedPacketIsDroppedButServerErrorIsKept() async {
        let r = make(b)
        r.recordPanelOpen()
        b.advance(days: 1)
        b.status = 503
        await send(r, b)
        #expect(r.state.days.count == 1)
        b.status = 400
        b.advance(days: 0, hours: 6)
        await send(r, b)
        #expect(r.state.days.isEmpty)
    }

    @Test func requestStaysOutOfLowDataModeAndHasShortTimeout() async {
        let r = make(b)
        r.recordPanelOpen()
        b.advance(days: 1)
        await send(r, b)
        let q = b.requests.first
        #expect(q?.allowsConstrainedNetworkAccess == false)
        #expect(q?.timeoutInterval == 10)
        #expect(q?.httpMethod == "POST")
        #expect(q?.httpShouldHandleCookies == false)
    }

    @Test func turningOffErasesEverything() {
        let r = make(b)
        r.recordPanelOpen()
        r.setEnabled(false)
        #expect(r.state == TelemetryRecorder.State())
        #expect(b.saved.map { (try? JSONDecoder().decode(TelemetryRecorder.State.self, from: $0)) } == .some(TelemetryRecorder.State()))
    }

    @Test func survivesARestart() {
        let r = make(b)
        r.recordPanelOpen()
        let again = TelemetryRecorder(load: { self.b.saved }, save: { _ in }, context: { fatalError() }, now: { start }, timeZone: utc)
        #expect(again.enabled)
        #expect(object(again.nextPayload().json)["panelOpens"] as? Int == 1)
    }

    @Test func offShowsTheFormatWithoutAnID() {
        let r = make(b, enabled: false)
        let shown = r.nextPayload()
        #expect(shown.isExample)
        #expect(object(shown.json)["installId"] as? String == "00000000-0000-0000-0000-000000000000")
    }

    @Test func yesterdaysPacketKeepsYesterdaysContext() async {
        let r = make(b)
        b.automation = true
        r.recordPanelOpen()
        b.automation = false
        b.family = nil
        r.recordPanelOpen() // o fone saiu e a regra foi desligada depois: o dia continua dizendo que houve
        b.advance(days: 1)
        let json = object(r.nextPayload().json)
        #expect(json["deviceModelFamily"] as? String == "WH-1000XM5")
        #expect((json["automation"] as? [String: Any])?["enabled"] as? Bool == true)
    }

    /// O mesmo arquivo é validado pela Lambda em `infra/telemetry/test`.
    @Test func packetMatchesTheSampleTheBackendValidates() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../../infra/telemetry/test/sample-v1.json")
        let sample = try Data(contentsOf: url)
        b.automation = true
        let r = make(b)
        r.recordModeChange(.panel)
        r.recordModeChange(.externalChange)
        r.recordTrigger(.call)
        r.recordOverride()
        for _ in 0..<60 { r.recordPanelOpen() }
        var sent = object(r.nextPayload().json)
        #expect(sent["installId"] != nil)
        sent["installId"] = object(sample)["installId"]
        #expect(NSDictionary(dictionary: sent).isEqual(to: object(sample)))
        #expect(sent.keys.contains("deviceModelFamily"))
        #expect((sent["automation"] as? [String: Any])?.keys.contains("trialDay") == true)
    }
}

@Suite struct ModeChangeTrackerTests {
    @Test func requestedChangeCountsForItsSource() {
        var t = ModeChangeTracker()
        _ = t.observe("off", at: start)
        t.expect(.user(.panel), at: start)
        #expect(t.observe("ambient", at: start + 0.1) == .panel)
    }

    @Test func askingForTheCurrentModeCountsNothing() {
        var t = ModeChangeTracker()
        _ = t.observe("off", at: start)
        t.expect(.user(.intent), at: start)
        #expect(t.observe("off", at: start + 0.1) == nil)
    }

    @Test func engineWriteIsNotManual() {
        var t = ModeChangeTracker()
        _ = t.observe("off", at: start)
        t.expect(.engine, at: start)
        #expect(t.observe("ambient", at: start + 0.1) == nil)
    }

    @Test func unannouncedChangeIsThePhysicalButton() {
        var t = ModeChangeTracker()
        _ = t.observe("off", at: start)
        #expect(t.observe("ambient", at: start + 1) == .externalChange)
        t.expect(.user(.hotkey), at: start)
        #expect(t.observe("off", at: start + 4) == .externalChange) // a intenção venceu
    }

    @Test func reopeningTheChannelIsNotAChange() {
        var t = ModeChangeTracker()
        _ = t.observe("off", at: start)
        #expect(t.observe(nil, at: start + 1) == nil)
        #expect(t.observe("ambient", at: start + 2) == nil)
    }
}

@Suite struct ModelFamilyTests {
    @Test func listMatchesTheSimulatorProfiles() {
        #expect(Set(ModelFamily.known) == Set(Profiles.all.map(\.modelName)))
    }

    @Test func knownNamesPassAndEverythingElseIsOther() {
        #expect(ModelFamily.normalize("WH-1000XM5") == "WH-1000XM5")
        #expect(ModelFamily.normalize("LinkBuds S") == "LinkBuds S")
        #expect(ModelFamily.normalize("Buchler Headphone") == "other")
        #expect(ModelFamily.normalize("WH-1000XM5 da Maria") == "WH-1000XM5")
        #expect(ModelFamily.normalize(nil) == nil)
    }
}
