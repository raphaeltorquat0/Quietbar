/// Última defesa da política de soltar o canal: a liberação por ociosidade depende de cada caminho agendá-la.
/// Decide só com o estado que recebe, e quem chama fecha com `MDRSession.forceDisconnect()`.
public struct ChannelWatchdog: Sendable {
    public struct Status: Sendable {
        public var channelOpen: Bool
        public var interfaceVisible: Bool
        /// Uma ação está usando o canal.
        public var busy: Bool
        public var lastActivity: ContinuousClock.Instant

        public init(channelOpen: Bool, interfaceVisible: Bool, busy: Bool, lastActivity: ContinuousClock.Instant) {
            self.channelOpen = channelOpen
            self.interfaceVisible = interfaceVisible
            self.busy = busy
            self.lastActivity = lastActivity
        }
    }

    public private(set) var closes = 0

    public init() {}

    /// `limit` é o tempo ocioso permitido. `true` conta um fechamento: o chamador deve fechar o canal.
    public mutating func shouldClose(_ s: Status, limit: Duration, now: ContinuousClock.Instant) -> Bool {
        guard s.channelOpen, !s.interfaceVisible, !s.busy, now - s.lastActivity >= limit else { return false }
        closes += 1
        return true
    }
}
