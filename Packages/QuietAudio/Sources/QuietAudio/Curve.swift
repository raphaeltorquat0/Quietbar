import Foundation

/// Um filtro do EQ paramétrico. Fórmulas do Audio EQ Cookbook (RBJ), as mesmas do AutoEQ.
public struct EQFilter: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case peak, lowShelf, highShelf }

    public var kind: Kind
    public var frequency: Double
    public var gain: Double
    public var q: Double

    public init(_ kind: Kind, frequency: Double, gain: Double, q: Double) {
        self.kind = kind
        self.frequency = frequency
        self.gain = gain
        self.q = q
    }

    public static let frequencyRange = 20.0...20_000.0
    public static let gainRange = -24.0...24.0
    public static let qRange = 0.1...20.0

    public var isValid: Bool {
        Self.frequencyRange.contains(frequency) && Self.gainRange.contains(gain) && Self.qRange.contains(q)
    }

    /// Coeficientes normalizados (a0 = 1). Acima de Nyquist vira neutro: o filtro não cabe nessa taxa.
    public func coefficients(sampleRate fs: Double) -> Biquad {
        guard frequency < fs / 2 * 0.98 else { return .identity }
        let a = pow(10, gain / 40), w = 2 * .pi * frequency / fs
        let cw = cos(w), alpha = sin(w) / (2 * q), root = 2 * a.squareRoot() * alpha
        let (b0, b1, b2, a0, a1, a2): (Double, Double, Double, Double, Double, Double)
        switch kind {
        case .peak:
            (b0, b1, b2) = (1 + alpha * a, -2 * cw, 1 - alpha * a)
            (a0, a1, a2) = (1 + alpha / a, -2 * cw, 1 - alpha / a)
        case .lowShelf:
            (b0, b1, b2) = (a * ((a + 1) - (a - 1) * cw + root), 2 * a * ((a - 1) - (a + 1) * cw), a * ((a + 1) - (a - 1) * cw - root))
            (a0, a1, a2) = ((a + 1) + (a - 1) * cw + root, -2 * ((a - 1) + (a + 1) * cw), (a + 1) + (a - 1) * cw - root)
        case .highShelf:
            (b0, b1, b2) = (a * ((a + 1) + (a - 1) * cw + root), -2 * a * ((a - 1) + (a + 1) * cw), a * ((a + 1) + (a - 1) * cw - root))
            (a0, a1, a2) = ((a + 1) - (a - 1) * cw + root, 2 * ((a - 1) - (a + 1) * cw), (a + 1) - (a - 1) * cw - root)
        }
        return Biquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }
}

public struct Biquad: Hashable, Sendable {
    public var b0, b1, b2, a1, a2: Double
    public static let identity = Biquad(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    /// |H(e^jw)|² avaliado direto na função de transferência.
    public func magnitudeSquared(frequency: Double, sampleRate fs: Double) -> Double {
        let w = 2 * .pi * frequency / fs
        let (c1, s1, c2, s2) = (cos(w), sin(w), cos(2 * w), sin(2 * w))
        let nr = b0 + b1 * c1 + b2 * c2, ni = b1 * s1 + b2 * s2
        let dr = 1 + a1 * c1 + a2 * c2, di = a1 * s1 + a2 * s2
        return (nr * nr + ni * ni) / (dr * dr + di * di)
    }
}

public struct EQCurve: Codable, Hashable, Sendable {
    public static let maxFilters = 10

    public var name: String
    public var filters: [EQFilter]

    public init(name: String, filters: [EQFilter]) {
        self.name = name
        self.filters = filters
    }

    /// Resposta combinada em dB, sem a pré-amplificação.
    public func responseDB(at frequency: Double, sampleRate fs: Double = 48_000) -> Double {
        filters.reduce(0) { $0 + 10 * log10($1.coefficients(sampleRate: fs).magnitudeSquared(frequency: frequency, sampleRate: fs)) }
    }

    /// Frequências log-espaçadas de 20 Hz a 20 kHz.
    public static func grid(_ points: Int) -> [Double] {
        (0..<points).map { 20 * pow(1000, Double($0) / Double(points - 1)) }
    }

    /// Ganho negativo que deixa o pico da resposta em 0 dB; 0 se a curva só atenua.
    public func autoPreampDB(sampleRate fs: Double = 48_000) -> Double {
        min(0, -(Self.grid(1024).map { responseDB(at: $0, sampleRate: fs) }.max() ?? 0))
    }
}

public enum CurveError: LocalizedError, Equatable {
    case invalidFile(String)
    case tooManyFilters(Int)
    case outOfRange(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFile(let d): "Arquivo de curva inválido: \(d)"
        case .tooManyFilters(let n): "A curva tem \(n) filtros; o limite é \(EQCurve.maxFilters)."
        case .outOfRange(let d): "Valor fora do limite: \(d)"
        }
    }
}

// MARK: - Importar e exportar

public extension EQCurve {
    /// Arquivo vem do usuário: tudo é validado antes de chegar à cadeia.
    func validated() throws -> EQCurve {
        guard filters.count <= Self.maxFilters else { throw CurveError.tooManyFilters(filters.count) }
        if let bad = filters.first(where: { !$0.isValid }) {
            throw CurveError.outOfRange("\(bad.kind.rawValue) \(bad.frequency) Hz, \(bad.gain) dB, Q \(bad.q)")
        }
        return self
    }

    private struct FileFormat: Codable {
        var format = "quietbar-eq"
        var version = 1
        var name: String
        var filters: [EQFilter]
    }

    static func parseJSON(_ data: Data) throws -> EQCurve {
        guard let f = try? JSONDecoder().decode(FileFormat.self, from: data), f.format == "quietbar-eq", f.version == 1 else {
            throw CurveError.invalidFile("JSON fora do formato quietbar-eq versão 1")
        }
        return try EQCurve(name: f.name, filters: f.filters).validated()
    }

    /// Lê uma curva do disco: `.json` no formato próprio, o resto como `ParametricEQ.txt`.
    static func load(from url: URL) throws -> EQCurve {
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) < 256_000 else {
            throw CurveError.invalidFile("arquivo grande demais")
        }
        let data = try Data(contentsOf: url)
        if url.pathExtension.lowercased() == "json" { return try parseJSON(data) }
        return try parseAutoEQ(String(decoding: data, as: UTF8.self), name: url.deletingPathExtension().lastPathComponent)
    }

    func jsonData() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(FileFormat(name: name, filters: filters))
    }

    /// `ParametricEQ.txt` do AutoEQ. A linha `Preamp` é ignorada: o app recalcula a pré-amplificação.
    static func parseAutoEQ(_ text: String, name: String) throws -> EQCurve {
        var filters: [EQFilter] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let t = raw.split(whereSeparator: \.isWhitespace).map(String.init)
            guard t.first == "Filter" else { continue }
            guard t.count >= 4, let on = t.firstIndex(where: { $0 == "ON" || $0 == "OFF" }) else {
                throw CurveError.invalidFile("linha ilegível: \(raw.prefix(60))")
            }
            if t[on] == "OFF" || t[on + 1] == "None" { continue }
            let kind: EQFilter.Kind
            switch t[on + 1] {
            case "PK", "PEQ": kind = .peak
            case "LSC", "LS": kind = .lowShelf
            case "HSC", "HS": kind = .highShelf
            default: throw CurveError.invalidFile("tipo de filtro \(t[on + 1]) não suportado")
            }
            func value(_ key: String) -> Double? {
                t.firstIndex(of: key).flatMap { t.indices.contains($0 + 1) ? Double(t[$0 + 1]) : nil }
            }
            guard let fc = value("Fc"), let gain = value("Gain") else {
                throw CurveError.invalidFile("linha sem Fc ou Gain: \(raw.prefix(60))")
            }
            filters.append(EQFilter(kind, frequency: fc, gain: gain, q: value("Q") ?? 0.7))
        }
        guard !filters.isEmpty else { throw CurveError.invalidFile("nenhum filtro encontrado") }
        return try EQCurve(name: name, filters: filters).validated()
    }

    func autoEQText() -> String {
        var lines = [String(format: "Preamp: %.1f dB", autoPreampDB())]
        for (i, f) in filters.enumerated() {
            let type = switch f.kind { case .peak: "PK"; case .lowShelf: "LSC"; case .highShelf: "HSC" }
            lines.append(String(format: "Filter %d: ON %@ Fc %.0f Hz Gain %.1f dB Q %.2f", i + 1, type, f.frequency, f.gain, f.q))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
