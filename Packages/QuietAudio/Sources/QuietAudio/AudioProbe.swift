import Foundation

/// Medição com a tap de verdade, compartilhada pelo `mdr-cli audio-probe` e pelo `Quietbar --audio-selftest`:
/// o CLI vindo de um shell não tem a permissão de gravar o áudio do sistema; o app assinado tem.
public enum AudioProbe {
    @available(macOS 14.2, *) @MainActor
    public static func measure(_ device: OutputDevice, seconds: Double, mute: Bool, tone: Bool, hold: Bool,
                               log: (String) -> Void) async -> Bool {
        log("dispositivo: \(device.name) \(device.sampleRate) Hz \(device.channels) canais")
        let chain = DSPChain()
        chain.set(curve: worstCase, sampleRate: device.sampleRate)
        let backend = CoreAudioBackend(chain: chain)
        var failure: String?
        backend.onFailure = { failure = $0 }
        backend.perform(.mount(device))
        try? await Task.sleep(for: .seconds(1))
        if let failure { log("falha ao montar: \(failure)"); return false }
        log(backend.routing)
        log("buffer: \(backend.grantedBufferFrames) quadros")
        if tone { chain.setTone(true); chain.setFade(open: true) }
        if mute { backend.perform(.arm); log("original mudo") }
        if hold { // fica montado até ser morto: é o que o teste de `kill -9` precisa
            log("segurando pid \(ProcessInfo.processInfo.processIdentifier)")
            try? await Task.sleep(for: .seconds(seconds))
            return true
        }

        let cpuStart = cpuSeconds(), wall = Date()
        var load: [Float] = [], latency: [Float] = [], peak: Float = 0
        var last = chain.readStats()
        while Date().timeIntervalSince(wall) < seconds {
            try? await Task.sleep(for: .milliseconds(100))
            last = chain.readStats()
            load.append(last.load)
            latency.append(last.latency)
            peak = max(peak, last.outputPeak)
        }
        let cpu = (cpuSeconds() - cpuStart) / Date().timeIntervalSince(wall) * 100
        backend.perform(.unmount)
        try? await Task.sleep(for: .milliseconds(300))
        func mean(_ x: [Float]) -> Float { x.reduce(0, +) / Float(max(x.count, 1)) }
        log(String(format: "quadros: %llu  último sinal: %llu  pico de saída: %.4f", last.frames, last.lastSignalFrame, peak))
        log(String(format: "carga do render: média %.3f%%  máx %.3f%%", mean(load) * 100, (load.max() ?? 0) * 100))
        log(String(format: "latência entrada→saída: média %.2f ms  máx %.2f ms", mean(latency) * 1000, (latency.max() ?? 0) * 1000))
        log(String(format: "CPU do processo: %.2f%%", cpu))
        if let failure { log("falha: \(failure)") }
        return last.frames > 0 && failure == nil
    }

    /// Custo da cadeia no pior caso (10 filtros), sem Core Audio: fração do tempo real que um núcleo gasta.
    public static func offlineLoad(sampleRate: Double = 48_000, seconds: Double = 10) -> Double {
        let chain = DSPChain()
        chain.set(curve: worstCase, sampleRate: sampleRate)
        chain.reset(sampleRate: sampleRate)
        chain.setFade(open: true)
        var g = SystemRandomNumberGenerator()
        var l = (0..<256).map { _ in Float.random(in: -0.5...0.5, using: &g) }, r = l
        let blocks = Int(seconds * sampleRate / 256)
        let t0 = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<blocks { chain.process(left: &l, right: &r) }
        return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9 / seconds
    }

    static let worstCase = EQCurve(name: "pior caso", filters: (0..<10).map {
        EQFilter(.peak, frequency: 40 * pow(1.9, Double($0)), gain: $0 % 2 == 0 ? 3 : -3, q: 1.2)
    })

    public static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return s(u.ru_utime) + s(u.ru_stime)
    }
}
