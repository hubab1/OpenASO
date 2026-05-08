import Foundation

@main
enum OpenASOMCPMain {
    static func main() async {
        do {
            try await OpenASOMCPRuntime.runStdio(
                configuration: OpenASOMCPServerConfiguration(version: "1.5.0")
            )
        } catch {
            FileHandle.standardError.write(Data("OpenASO MCP server failed: \(error)\n".utf8))
            Foundation.exit(1)
        }
    }
}
