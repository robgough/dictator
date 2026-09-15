import Foundation
import MLXLMCommon

/// A tool the chat agent can call, from whatever source.
struct ChatTool: Sendable {
    /// The name the model sees. Unique across every source.
    let name: String
    /// Shown in the transcript and the approval sheet.
    let displayName: String
    let detail: String
    let spec: ToolSpec
    /// Which MCP server provides it; nil for a built-in.
    let serverID: UUID?
    let serverName: String?
    /// Read-only tools that can't leak anything the user hasn't already got on
    /// screen run without asking. Anything that reads private state or changes
    /// something asks first.
    let isSafeWithoutApproval: Bool
}
