import Darwin

extension GDP {
    /// libgdp sends on plain UDP sockets, without SO_NOSIGPIPE. iOS can make
    /// such a socket defunct under the app, as it did when the user granted
    /// local network access mid-login, and the next send then raises
    /// SIGPIPE, whose default action ends the process without a crash
    /// report. Ignored for the whole process before the first socket opens,
    /// the send just fails with EPIPE and libgdp handles it as any other.
    static let ignoreBrokenPipes: Void = { signal(SIGPIPE, SIG_IGN) }()
}
