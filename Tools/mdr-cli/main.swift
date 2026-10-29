import Foundation
import MDRKit
import MDRSession
import MDRTransport

let usage = """
uso: mdr-cli <comando> [--address AA:BB:CC:DD:EE:FF] [--log-hex]

  list                      fones pareados e se anunciam o serviço Sony MDR v2
  dump                      conecta, faz o handshake e imprime capacidades e estado
  get <campo>               imprime um campo do dump (ex.: get battery)
  set <campo> <valor>       altera um ajuste e imprime o valor relido do fone
  send <hex> [--t2]         envia um payload cru (ex.: send "66 17") e mostra as respostas
  sniff                     conecta e imprime todo o tráfego até Ctrl-C
  popup                     pede ao app aberto para mostrar o popup de conexão
  ble-scan [s] [--all]      procura anúncios BLE Fast Pair (0xFE2C); padrão 15 s
  model --export <f.usdz>   exporta o modelo 3D do app (Quick Look)
  model --snapshot <f.png>  renderiza offscreen [--state nc|ambient|off] [--battery 0-1]
                            [--view three-quarter|front|side|top] [--renderer scenekit|realitykit]

campos de set:
  mode nc|ambient|off       ambient 0-20            voice on|off
  eq <preset hex|nome>      eq-bands <cb,b1,b2,b3,b4,b5> (dB −10…10)
  dsee on|off               stc on|off              stc-sens auto|high|low
  stc-time short|mid|long|none                      autopause on|off
  autooff 5m|15m|30m|1h|3h|removed|never            button nc-amb-off|nc-amb|nc-off|amb-off
  priority quality|stability                        multipoint on|off
  touch on|off              gs <D1-D4> on|off       volume 0-30
  play | pause | next | prev | poweroff (sem valor)

--log-hex imprime cada frame em stderr (>> enviado, << recebido) para anexar em issues.
"""

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

func eprint(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

let startTime = Date()

func hexLogger(_ dir: MDRSession.Direction, _ bytes: [UInt8]) {
    let t = String(format: "%8.3f", Date().timeIntervalSince(startTime))
    var line = "\(t) \(dir == .tx ? ">>" : "<<") \(bytes.hex)"
    if let d = MDRFrame.describe(bytes) { line += "    \(d)" }
    eprint(line)
}

// MARK: - Descrição do estado

func hex(_ b: UInt8) -> String { String(format: "0x%02X", b) }
func fields(_ s: MDRDeviceState) -> [(String, String)] { s.diagnosticFields }

// MARK: - set

func parseOnOff(_ v: String) throws -> Bool {
    switch v.lowercased() {
    case "on", "1", "true", "sim": return true
    case "off", "0", "false", "nao", "não": return false
    default: throw CLIError("esperado on|off, veio \(v)")
    }
}

func apply(_ field: String, _ value: String?, on session: MDRSession) async throws {
    let st = await session.state
    func need() throws -> String {
        guard let value else { throw CLIError("\(field) precisa de valor") }
        return value
    }
    switch field {
    case "mode":
        let m: SoundMode = switch try need() {
        case "nc": .noiseCanceling
        case "ambient", "amb": .ambient
        case "off": .off
        default: throw CLIError("mode nc|ambient|off")
        }
        try await session.setSoundMode(m)
    case "ambient": try await session.setAmbientLevel(Int(try need()) ?? -1)
    case "voice": try await session.setFocusOnVoice(try parseOnOff(try need()))
    case "eq":
        let v = try need()
        let byName = st.equalizerPresets.first { $0.displayName.caseInsensitiveCompare(v) == .orderedSame }?.id
            ?? EqPreset.knownNames.first { $0.value.caseInsensitiveCompare(v) == .orderedSame }?.key
        guard let id = byName ?? UInt8(v.replacingOccurrences(of: "0x", with: ""), radix: 16) else {
            throw CLIError("preset desconhecido: \(v)")
        }
        try await session.setEqualizerPreset(id)
    case "eq-bands":
        let n = try need().split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard n.count == 6 else { throw CLIError("eq-bands espera 6 números: clearBass,400,1k,2.5k,6.3k,16k") }
        try await session.setEqualizer(clearBass: n[0], bands: Array(n[1...]))
    case "dsee": try await session.setDSEE(try parseOnOff(try need()))
    case "stc": try await session.setSpeakToChat(try parseOnOff(try need()))
    case "stc-sens", "stc-time":
        var c = st.speakToChatConfig ?? SpeakToChatConfig(sensitivity: 0, modeOutTime: 1)
        let v = try need()
        if field == "stc-sens" {
            guard let i = ["auto", "high", "low"].firstIndex(of: v) else { throw CLIError("stc-sens auto|high|low") }
            c.sensitivity = UInt8(i)
        } else {
            guard let i = ["short", "mid", "long", "none"].firstIndex(of: v) else { throw CLIError("stc-time short|mid|long|none") }
            c.modeOutTime = UInt8(i)
        }
        try await session.setSpeakToChatConfig(c)
    case "autopause": try await session.setAutoPause(try parseOnOff(try need()))
    case "autooff":
        let map: [String: UInt8] = ["5m": 0x00, "15m": 0x04, "30m": 0x01, "1h": 0x02, "3h": 0x03, "removed": 0x10, "never": 0x11]
        guard let e = map[try need()] else { throw CLIError("autooff 5m|15m|30m|1h|3h|removed|never") }
        try await session.setAutoPowerOff(e)
    case "button":
        let map: [String: NcAmbButtonFunction] = ["nc-amb-off": .ncAmbientOff, "nc-amb": .ncAmbient, "nc-off": .ncOff, "amb-off": .ambientOff]
        guard let fn = map[try need()] else { throw CLIError("button nc-amb-off|nc-amb|nc-off|amb-off") }
        try await session.setNcAmbButton(fn)
    case "priority":
        let v = try need()
        guard v == "quality" || v == "stability" else { throw CLIError("priority quality|stability") }
        try await session.setConnectionPriority(v == "quality" ? .soundQuality : .stability)
    case "multipoint", "touch":
        let subject = field == "multipoint" ? "MULTIPOINT_SETTING" : "TOUCH_PANEL_SETTING"
        guard let gs = st.generalSetting(subject: subject) else { throw CLIError("o fone não anuncia \(subject)") }
        try await session.setGeneralSetting(gs.type, on: try parseOnOff(try need()))
    case "gs":
        let parts = try need().split(separator: " ")
        guard parts.count == 2, let t = UInt8(parts[0].replacingOccurrences(of: "0x", with: ""), radix: 16) else {
            throw CLIError("gs \"D1 on\"")
        }
        try await session.setGeneralSetting(t, on: try parseOnOff(String(parts[1])))
    case "volume": try await session.setVolume(Int(try need()) ?? 0)
    case "play": try await session.playback(.play)
    case "pause": try await session.playback(.pause)
    case "next": try await session.playback(.next)
    case "prev": try await session.playback(.previous)
    case "poweroff": try await session.powerOff()
    default: throw CLIError("campo desconhecido: \(field)\n\n\(usage)")
    }
}

// MARK: - Execução

@MainActor
func run(_ argv: [String]) async throws {
    var args = argv
    let logHex = args.contains("--log-hex")
    let t2 = args.contains("--t2")
    args.removeAll { $0 == "--log-hex" || $0 == "--t2" }
    var address: String?
    if let i = args.firstIndex(of: "--address"), i + 1 < args.count {
        address = args[i + 1].uppercased().replacingOccurrences(of: "-", with: ":")
        args.removeSubrange(i...(i + 1))
    }
    guard let command = args.first else { print(usage); return }

    if command == "list" {
        let devices = BluetoothDevices.paired()
        if devices.isEmpty { print("Nenhum dispositivo pareado (ou o Terminal não tem permissão de Bluetooth).") }
        for d in devices {
            print("\(d.address)  \(d.isConnected ? "conectado   " : "desconectado")  MDRv2=\(d.hasMDRService ? "sim" : "?  ")  \(d.name)")
        }
        return
    }
    if command == "bench" { return try await runBench() }
    if command == "model" { return try await runModel(Array(args.dropFirst())) }
    if command == "popup" {
        // O app escuta esta notificação; sem userInfo para funcionar com App Sandbox.
        DistributedNotificationCenter.default().postNotificationName(.init("io.github.raphaeltorquat0.quietbar.showPopup"), object: nil,
                                                                     userInfo: nil, deliverImmediately: true)
        return
    }
    if command == "ble-scan" {
        return try await runBLEScan(seconds: args.dropFirst().first.flatMap(Double.init) ?? 15, showAll: args.contains("--all"))
    }
    guard ["dump", "get", "set", "send", "sniff"].contains(command) else { print(usage); return }

    guard let target = address ?? BluetoothDevices.preferredSony()?.address else {
        throw CLIError("nenhum fone Sony pareado encontrado; use --address")
    }
    eprint("conectando em \(target)…")
    let sniffing = command == "sniff"
    let session = MDRSession(channel: RFCOMMChannel(address: target),
                             traffic: logHex || sniffing || command == "send" ? hexLogger : nil)
    try await session.connect()
    try await Task.sleep(for: .milliseconds(800)) // as RETs do sync chegam logo depois dos ACKs

    switch command {
    case "dump":
        for (k, v) in fields(await session.state) { print(k.padding(toLength: 16, withPad: " ", startingAt: 0) + v) }
    case "get":
        guard args.count >= 2 else { throw CLIError("get <campo>") }
        guard let v = fields(await session.state).first(where: { $0.0 == args[1] })?.1 else {
            throw CLIError("campo desconhecido: \(args[1])")
        }
        print(v)
    case "set":
        guard args.count >= 2 else { throw CLIError("set <campo> <valor>") }
        try await apply(args[1], args.count > 2 ? args[2...].joined(separator: " ") : nil, on: session)
        try await Task.sleep(for: .milliseconds(500))
        if let a = await session.state.pendingAlert {
            eprint("o fone pediu confirmação (alerta \(hex(a.messageType))); respondendo positivo")
            try await session.respondToAlert(positive: true)
            try await Task.sleep(for: .milliseconds(500))
        }
        let key = ["eq-bands": "eq-bands", "stc-sens": "stc-config", "stc-time": "stc-config", "multipoint": "gs", "touch": "gs"][args[1]] ?? args[1]
        for (k, v) in fields(await session.state) where k.hasPrefix(key) { print("\(k) = \(v)") }
    case "send":
        guard args.count >= 2 else { throw CLIError("send \"66 17\"") }
        let bytes = args[1...].joined(separator: " ").split(whereSeparator: { $0 == " " || $0 == "," })
            .compactMap { UInt8($0.replacingOccurrences(of: "0x", with: ""), radix: 16) }
        try await session.send(MDRCommand(bytes, table: t2 ? .t2 : .t1))
        try await Task.sleep(for: .seconds(1))
    default: // sniff
        eprint("ouvindo; aperte os botões do fone. Ctrl-C para sair.")
        for await snap in await session.snapshots() where snap.phase == .disconnected {
            eprint("canal fechado pelo fone")
            break
        }
    }
    await session.disconnect()
}

Task { @MainActor in
    do {
        try await run(Array(CommandLine.arguments.dropFirst()))
        exit(0)
    } catch {
        eprint("erro: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
        exit(1)
    }
}
RunLoop.main.run() // o IOBluetooth entrega os callbacks no run loop principal
