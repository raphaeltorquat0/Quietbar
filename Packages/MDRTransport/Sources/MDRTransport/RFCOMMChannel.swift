import Foundation
import IOBluetooth
import MDRKit

public enum MDRServiceUUID {
    /// Serviço Sony MDR v2 (docs/PROTOCOL.md §1).
    public static let v2 = "956C7B26-D49A-4BA8-B03F-B17D393CB6E2"

    static var v2SDP: IOBluetoothSDPUUID {
        let hex = v2.replacingOccurrences(of: "-", with: "")
        var bytes = stride(from: 0, to: hex.count, by: 2).map {
            let i = hex.index(hex.startIndex, offsetBy: $0)
            return UInt8(hex[i...hex.index(after: i)], radix: 16)!
        }
        return IOBluetoothSDPUUID(bytes: &bytes, length: bytes.count)
    }
}

public enum MDRTransportError: Error, LocalizedError, Sendable {
    case deviceNotFound(String)
    case serviceNotFound
    case noChannelID
    case openFailed(IOReturn)
    case writeFailed(IOReturn)
    case notOpen

    public var errorDescription: String? {
        switch self {
        case .deviceNotFound(let a): "Dispositivo \(a) não está pareado"
        case .serviceNotFound: "O dispositivo não anuncia o serviço Sony MDR v2 (é um fone Sony recente e está ligado?)"
        case .noChannelID: "O registro SDP do serviço Sony não tem canal RFCOMM"
        case .openFailed(let r): String(format: "Falha ao abrir o canal RFCOMM (0x%08X)", r)
        case .writeFailed(let r): String(format: "Falha ao escrever no RFCOMM (0x%08X)", r)
        case .notOpen: "Canal RFCOMM fechado"
        }
    }
}

/// Canal RFCOMM até o serviço Sony MDR v2. Todo acesso ao IOBluetooth roda na main thread,
/// que é onde o framework entrega os callbacks (precisa de run loop ativo — no CLI, `RunLoop.main.run()`).
@MainActor
public final class RFCOMMChannel: NSObject, MDRChannel {
    public let address: String
    private let openTimeout: Duration
    private var channel: IOBluetoothRFCOMMChannel?
    private var incoming: AsyncStream<[UInt8]>.Continuation?
    private var pendingOpen: CheckedContinuation<Void, Error>?
    private var pendingSDP: CheckedContinuation<Void, Never>?
    /// Etapas da conexão, para `mdr-cli --trace`.
    public var trace: ((String) -> Void)?

    /// Abrir o canal leva menos de 0,5 s; a sessão tenta de novo em caso de timeout.
    public init(address: String, openTimeout: Duration = .seconds(4)) {
        self.address = address
        self.openTimeout = openTimeout
    }

    public func open() async throws -> AsyncStream<[UInt8]> {
        closeChannel()
        guard let device = IOBluetoothDevice(addressString: address) else { throw MDRTransportError.deviceNotFound(address) }
        trace?("dispositivo: conectado=\(device.isConnected()) emparelhado=\(device.isPaired())")

        var record = device.getServiceRecord(for: MDRServiceUUID.v2SDP)
        trace?("SDP \(MDRServiceUUID.v2): \(record == nil ? "fora do cache, consultando o fone" : "em cache")")
        if record == nil {
            // Registro SDP ainda não está em cache: consulta o fone.
            await withCheckedContinuation { c in
                pendingSDP = c
                if device.performSDPQuery(self, uuids: [MDRServiceUUID.v2SDP]) != kIOReturnSuccess { finishSDP() }
            }
            record = device.getServiceRecord(for: MDRServiceUUID.v2SDP)
        }
        guard let record else {
            trace?("SDP: serviço não encontrado")
            throw MDRTransportError.serviceNotFound
        }
        var channelID: BluetoothRFCOMMChannelID = 0
        guard record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else { throw MDRTransportError.noChannelID }
        trace?("SDP: canal RFCOMM \(channelID)")

        let (stream, continuation) = AsyncStream.makeStream(of: [UInt8].self)
        incoming = continuation
        let timeout = Task { [openTimeout] in
            try? await Task.sleep(for: openTimeout)
            self.failOpen(MDRChannelOpenTimeout())
        }
        defer { timeout.cancel() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            pendingOpen = c
            var ch: IOBluetoothRFCOMMChannel?
            let r = device.openRFCOMMChannelAsync(&ch, withChannelID: channelID, delegate: self)
            trace?(String(format: "RFCOMM: abertura pedida, retorno 0x%08X", UInt32(bitPattern: r)))
            if r != kIOReturnSuccess { failOpen(MDRTransportError.openFailed(r)) } else { channel = ch }
        }
        return stream
    }

    public func write(_ bytes: [UInt8]) async throws {
        guard let channel, channel.isOpen() else { throw MDRTransportError.notOpen }
        let mtu = max(1, Int(channel.getMTU()))
        var offset = 0
        while offset < bytes.count {
            var chunk = Array(bytes[offset..<min(offset + mtu, bytes.count)])
            let r = chunk.withUnsafeMutableBytes { channel.writeSync($0.baseAddress, length: UInt16($0.count)) }
            guard r == kIOReturnSuccess else { throw MDRTransportError.writeFailed(r) }
            offset += chunk.count
        }
    }

    public func close() async { closeChannel() }

    /// Fecha só o canal de controle. Nunca derruba a conexão de áudio (`closeConnection`).
    func closeChannel() {
        if let ch = channel {
            ch.setDelegate(nil)
            ch.close()
        }
        channel = nil
        incoming?.finish()
        incoming = nil
        failOpen(MDRTransportError.notOpen)
    }

    private func failOpen(_ error: Error) {
        pendingOpen?.resume(throwing: error)
        pendingOpen = nil
    }

    private func finishSDP() {
        pendingSDP?.resume()
        pendingSDP = nil
    }
}

extension RFCOMMChannel: IOBluetoothRFCOMMChannelDelegate {
    public nonisolated func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        let mtu = Int(rfcommChannel?.getMTU() ?? 0)
        MainActor.assumeIsolated {
            trace?(String(format: "RFCOMM: abertura concluída, status 0x%08X, MTU %d", UInt32(bitPattern: error), mtu))
            if error == kIOReturnSuccess {
                pendingOpen?.resume()
                pendingOpen = nil
            } else {
                channel = nil
                failOpen(MDRTransportError.openFailed(error))
            }
        }
    }

    public nonisolated func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        let bytes = Array(UnsafeRawBufferPointer(start: dataPointer, count: dataLength))
        MainActor.assumeIsolated { _ = incoming?.yield(bytes) }
    }

    public nonisolated func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        let closed = rfcommChannel.map(ObjectIdentifier.init)
        MainActor.assumeIsolated {
            trace?("RFCOMM: canal fechado pelo outro lado")
            guard closed == channel.map(ObjectIdentifier.init) else { return }
            channel = nil
            incoming?.finish()
            incoming = nil
        }
    }

    /// Callback informal de `performSDPQuery(_:uuids:)`.
    @objc public nonisolated func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        MainActor.assumeIsolated { finishSDP() }
    }
}
