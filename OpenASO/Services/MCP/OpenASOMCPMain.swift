import Foundation

@main
enum OpenASOMCPMain {
    static func main() async {
        do {
            try await OpenASOMCPRuntime.runStdio(
                configuration: OpenASOMCPServerConfiguration(version: "1.5.0")
            )
        } catch {
            let description = (error as? PersistentStoreError)?.diagnosticReport
                ?? String(reflecting: error)
            FileHandle.standardError.write(Data("OpenASO MCP server failed: \(description)\n".utf8))
            Foundation.exit(1)
        }
    }
}
