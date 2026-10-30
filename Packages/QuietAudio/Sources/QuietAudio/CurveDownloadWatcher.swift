import Foundation

/// Espera o `ParametricEQ.txt` aparecer numa pasta. Consulta só esses nomes, um a um: não lista a pasta
/// nem abre nenhum outro arquivo. O que já existia ao começar não conta como novo.
public struct CurveDownloadWatcher {
    public static let names = ["ParametricEQ", "Sony WH-1000XM5 ParametricEQ"]

    private let candidates: [URL]
    private var seen: [URL: Date] = [:]

    public init(directory: URL) {
        // O navegador acrescenta " (1)" quando o nome já existe.
        candidates = Self.names.flatMap { name in
            ["", " (1)", " (2)", " (3)"].map { directory.appending(path: "\(name)\($0).txt") }
        }
        for url in candidates { seen[url] = Self.date(url) }
    }

    /// Curva nova ou alterada desde a última consulta. Arquivo que não é uma curva válida é ignorado.
    public mutating func poll() -> (url: URL, curve: EQCurve)? {
        for url in candidates {
            guard let date = Self.date(url), date != seen[url] else { continue }
            seen[url] = date
            if let curve = try? EQCurve.load(from: url) { return (url, curve) }
        }
        return nil
    }

    private static func date(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
