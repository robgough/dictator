import Foundation

/// How a client talks to one MCP server.
///
/// Two shapes with almost nothing in common underneath: stdio owns a
/// subprocess and multiplexes a long-lived duplex pipe by request id, while
/// Streamable HTTP makes one POST per message and may get its answer as a
/// plain JSON body *or* as an SSE stream it has to read until the matching
/// response arrives. Putting request/response behind this protocol is what
/// keeps `MCPClient` free of that: it does handshake, tool listing and tool
/// calls, and never learns which kind it is talking to.
protocol MCPTransport: Actor {
    /// Bring the connection up far enough to send `initialize`.
    func connect() async throws

    /// Send a JSON-RPC request and wait for its response `result`.
    /// Throws `MCPError.rpc` when the server answers with an error object.
    func request(_ method: String, params: MCPJSON?, timeout: Int) async throws -> MCPJSON

    /// Send a JSON-RPC notification. Fire and forget — no id, no reply.
    func notify(_ method: String, params: MCPJSON?) async throws

    /// Called once the handshake settles, so a transport that needs the
    /// negotiated version on later requests (HTTP does; stdio doesn't) has it.
    func setNegotiatedProtocolVersion(_ version: String) async

    /// Tear down. Must be safe to call more than once.
    func disconnect() async

    /// Whatever the transport can say about *why* something failed — a stdio
    /// server's stderr tail, an HTTP status line. Surfaced in the Settings row,
    /// because "it didn't work" is useless and "Error: GITHUB_TOKEN is not set"
    /// is the whole answer.
    var diagnostics: String { get }
}
