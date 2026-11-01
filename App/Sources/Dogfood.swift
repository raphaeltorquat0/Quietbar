import AppKit
import Carbon.HIToolbox
import MDRKit
import MDRSession
import QuietAudio
import QuietAutomation
import QuietTelemetry
import ServiceManagement
import SwiftUI

/// Teste interno: registra o uso em JSONL, só neste Mac. Nada daqui vai para a rede (docs/DOGFOOD.md).
/// Nome de rede só em hash, e o estado vem do que o app já sabe: nunca abre o canal nem manda SET.
@MainActor
final class Dogfood {
    static let shared = Dogfood()
    /// Com sandbox, fica no contêiner do app. O caminho em `~/Library` é um link: ver DECISIONS.md #165.
    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Quietbar/dogfood")

    private let log = DogfoodLog(directory: directory)
    private var audit = SetAudit()
    private var pending: [String: Any?]?
    private var call: (started: Date, apps: [String])?
    private var started = false

    private static let sample = Duration.seconds(300)

    private var enabled: Bool { AppSettings.shared.dogfoodEnabled }

    func start() {
        guard !started else { return }
        started = true
        record("app.open", Self.about())
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                Dogfood.shared.record("app.close")
                Dogfood.shared.log.flush()
            }
        }
        Task {
            var cpu = AudioProbe.cpuSeconds(), time = Date()
            while true {
                try? await Task.sleep(for: Self.sample)
                let nowCPU = AudioProbe.cpuSeconds(), now = Date()
                let sound = MacSound.shared
                if sound.isOn, let engine = sound.engine {
                    record("macsound.sample", ["phase": "\(engine.phase)", "latencyMs": Double(engine.latency) * 1000,
                                               "load": Double(engine.load), "cpuPct": (nowCPU - cpu) / now.timeIntervalSince(time) * 100])
                }
                (cpu, time) = (nowCPU, now)
            }
        }
    }

    func enabledChanged(_ on: Bool) {
        log.append(on ? "dogfood.on" : "dogfood.off", Self.about())
        HotKeys.shared.register()
    }

    func record(_ event: String, _ fields: [String: Any?] = [:]) {
        guard enabled else { return }
        log.append(event, fields)
    }

    private static func about() -> [String: Any?] {
        let info = Bundle.main.infoDictionary
        return ["version": info?["CFBundleShortVersionString"], "build": info?["CFBundleVersion"],
                "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
                "loginItem": SMAppService.mainApp.status == .enabled]
    }

    private var mode: String? { DeviceController.shared.state.noiseControl?.soundMode.rawValue }

    /// Perfil de Wi-Fi costuma levar o nome da rede: nessa camada, o nome só sai em hash.
    private func name(of kind: RuleKind?) -> String? {
        guard let kind, let rule = Automation.shared.engine.rules[kind] else { return nil }
        return kind == .wifi ? log.hash(rule.name) : rule.name
    }

    private func kind(_ text: String?) -> RuleKind? {
        RuleKind.allCases.first { String(describing: $0) == text }
    }

    // MARK: - Motor

    func handle(_ event: AutomationEvent) {
        guard enabled else { return }
        let rule = kind(event.rule)
        switch event.kind {
        case .write:
            pending = ["rule": event.rule, "name": name(of: rule), "from": mode, "to": event.fields?["soundMode"], "fields": event.fields]
        case .confirm:
            guard var done = pending else { return }
            pending = nil
            done["ackMs"] = event.latencyMs
            let by = done["rule"] as? String
            record(by == "default" ? "rule.undone" : by == "manual" ? "manual.applied" : "rule.applied", done)
        case .divergence:
            guard var done = pending else { return }
            pending = nil
            done["seen"] = event.fields
            record("rule.divergence", done)
        case .decision where event.fields?.isEmpty != false:
            record("rule.noop", ["rule": event.rule, "name": name(of: rule), "mode": mode])
        case .ruleStarted where event.trigger == "app" || event.trigger == "wifi":
            record("profile.applied", ["kind": event.trigger, "name": name(of: kind(event.trigger))])
        case .manual where event.trigger == "channelReopened":
            record("manual", ["source": "channelReopened", "to": event.fields?["soundMode"], "late": true])
        case .manual where event.trigger == "applyManually":
            record("manual", ["source": "intent", "fields": event.fields])
        case .manual where event.fields?["soundMode"] == nil:
            record("manual", ["source": "other", "fields": event.fields]) // o modo chega por `manual(_:to:)`, com a origem
        case .overrideEnded: record("override.end")
        case .unavailable: record("rule.pending", ["rule": event.rule])
        case .verified: record("rule.check", ["result": "verified", "ms": event.latencyMs])
        case .unverified: record("rule.check", ["result": "unverified", "ms": event.latencyMs])
        case .failure: record("protocol.error", ["kind": "automation", "error": event.fields?["error"]])
        default: break
        }
    }

    /// Só troca de modo que a automação não pediu: `ModeChangeTracker` já descartou as dela.
    func manual(_ source: ModeSource, to mode: SoundMode?) {
        record("manual", ["source": source.rawValue, "to": mode?.rawValue])
    }

    // MARK: - Chamada

    func callChanged(_ active: Bool, apps: [String]?) {
        if active, call == nil {
            let device = DeviceController.shared
            call = (Date(), apps ?? [])
            record("call.start", ["apps": apps, "wanted": AppSettings.shared.callMode.rawValue,
                                  "headphone": device.isBluetoothConnected, "mode": mode])
        } else if !active, let open = call {
            call = nil
            record("call.end", ["apps": open.apps, "durationS": Int(Date().timeIntervalSince(open.started))])
        }
    }

    // MARK: - Fone

    func traffic(_ direction: MDRSession.Direction, _ bytes: [UInt8]) {
        guard enabled else { return }
        switch audit.observe(direction, bytes) {
        case .sent(let message): record("set.sent", ["message": message])
        case .redundant(let message): record("set.redundant", ["message": message])
        case .malformed: record("protocol.error", ["kind": "frame", "bytes": bytes.count])
        case nil: break
        }
    }

    func channelChanged(from old: MDRSession.Phase, to new: MDRSession.Phase, reason: String?) {
        switch new {
        case .ready: record("channel.open")
        case .failed(let error): record("protocol.error", ["kind": "channel", "error": error])
        case .disconnected where old == .ready: record("channel.close", ["reason": reason ?? "unexpected"])
        default: break
        }
    }

    // MARK: - Momentos

    func markMoment() {
        guard enabled else { return }
        let id = UUID().uuidString
        record("moment", ["id": id, "state": state()])
        MomentPanel.shared.present { note in
            Dogfood.shared.record("moment.note", ["id": id, "note": note])
        }
    }

    /// O app inteiro, como ele se enxerga neste instante.
    private func state() -> [String: Any?] {
        let device = DeviceController.shared, automation = Automation.shared, sound = MacSound.shared
        let engine = automation.engine, s = device.state, c = engine.counters
        let rules = engine.rules.reduce(into: [String: String?]()) { $0[String(describing: $1.key)] = name(of: $1.key) }
        let manual = engine.manual.reduce(into: [String: String]()) { $0[String(describing: $1.key)] = "\($1.value)" }
        let active: Any? = switch engine.active {
        case nil: nil
        case .manual: "manual"
        case .rule(let kind, _): String(describing: kind)
        }
        return [
            "version": Diagnostics.appVersion, "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "channel": "\(device.snapshot.phase)", "bluetooth": device.isBluetoothConnected,
            "model": s.modelName, "firmware": s.firmwareVersion,
            "mode": mode, "ambientLevel": s.noiseControl.map { Int($0.ambientLevel) }, "focusOnVoice": s.noiseControl?.focusOnVoice,
            "eqPreset": s.equalizer.map { Int($0.presetID) }, "speakToChat": s.speakToChat,
            "battery": device.lastBattery.map { Int($0.level) }, "lastError": device.lastError,
            "ruleActive": active, "rules": rules.compactMapValues { $0 }, "manual": manual,
            "writes": c.writes, "confirmed": c.confirmed, "divergent": c.divergent, "failed": c.failed,
            "redundantBlocked": c.redundantBlocked, "overridesKept": c.overridesKept, "unverified": c.unverified,
            "watchdogCloses": device.watchdogCloses, "inCall": call != nil, "micApps": automation.micUsage.processes,
            "frontApp": ProfileEngine.shared.frontmostBundleID, "wifiHash": ProfileEngine.shared.currentSSID.map(log.hash),
            "macSound": sound.isOn, "macSoundPreset": sound.preset.rawValue, "macSoundStatus": sound.engine.map { "\($0.phase)" },
        ].compactMapValues { $0 }
    }
}

extension KeyCombo {
    /// ⌃⌥⌘M
    static let moment = KeyCombo(keyCode: UInt32(kVK_ANSI_M), carbonModifiers: UInt32(controlKey | optionKey | cmdKey), display: "⌃⌥⌘M")
}

/// Campo curto do "marcar momento". Não ativa o app: o que estava em primeiro plano não perde o foco.
@MainActor
final class MomentPanel {
    static let shared = MomentPanel()

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override func cancelOperation(_ sender: Any?) { MomentPanel.shared.close() }
    }

    private var panel: NSPanel?

    func present(_ save: @escaping (String) -> Void) {
        close()
        let p = Panel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 92), styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        p.title = String(localized: "Marcar momento")
        p.level = .floating
        p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView: MomentField { note in
            if !note.isEmpty { save(note) }
            MomentPanel.shared.close()
        })
        p.center()
        p.makeKeyAndOrderFront(nil)
        panel = p
    }

    private func close() {
        panel?.close()
        panel = nil
    }
}

private struct MomentField: View {
    let done: (String) -> Void
    @State private var note = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("O que aconteceu?", text: $note)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { done(note.trimmingCharacters(in: .whitespacesAndNewlines)) }
            Text("O estado do app já foi gravado. Return salva, Esc fecha sem texto.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .onAppear { focused = true }
    }
}
