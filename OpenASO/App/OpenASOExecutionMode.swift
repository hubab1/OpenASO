enum OpenASOExecutionMode: Equatable, Sendable {
    static let mcpStdioArgument = "--mcp-stdio"

    case graphical
    case mcpStdio
    case backgroundRefresh

    init(arguments: [String]) {
        if arguments.contains(BackgroundRefreshRuntime.argument) {
            self = .backgroundRefresh
        } else if arguments.contains(Self.mcpStdioArgument) {
            self = .mcpStdio
        } else {
            self = .graphical
        }
    }

    var suppressesApplicationUI: Bool {
        self != .graphical
    }
}
