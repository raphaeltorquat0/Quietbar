import Testing
@testable import QuietAudio

@Suite struct MicUsageTests {
    @Test func stoppedInputIsNeverACall() {
        #expect(!MicUsage(deviceRunning: false, processes: ["us.zoom.xos"]).inCall(ignoring: []))
    }

    @Test func anyAppCounts() {
        #expect(MicUsage(deviceRunning: true, processes: ["us.zoom.xos"]).inCall(ignoring: []))
    }

    @Test func ignoredAppDoesNotCount() {
        #expect(!MicUsage(deviceRunning: true, processes: ["com.apple.VoiceMemos"]).inCall(ignoring: ["com.apple.VoiceMemos"]))
    }

    @Test func ignoringAnAppCoversItsHelpers() {
        #expect(!MicUsage(deviceRunning: true, processes: ["com.google.Chrome.helper"]).inCall(ignoring: ["com.google.Chrome"]))
        #expect(MicUsage(deviceRunning: true, processes: ["com.google.Chromebook"]).inCall(ignoring: ["com.google.Chrome"]))
    }

    @Test func callWinsOverAnIgnoredAppRunningTogether() {
        #expect(MicUsage(deviceRunning: true, processes: ["com.apple.VoiceMemos", "us.zoom.xos"]).inCall(ignoring: ["com.apple.VoiceMemos"]))
    }

    @Test func runningOnlyForThisAppIsNotACall() {
        #expect(!MicUsage(deviceRunning: true, processes: []).inCall(ignoring: []))
    }

    @Test func withoutProcessListTheInputAloneDecides() {
        #expect(MicUsage(deviceRunning: true, processes: nil).inCall(ignoring: ["us.zoom.xos"]))
    }
}
