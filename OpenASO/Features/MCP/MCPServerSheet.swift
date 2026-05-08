import AppKit
import SwiftUI

struct MCPServerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let controller: OpenASOMCPServerController
    let settingsStore: AppSettingsStore

    @State private var selectedTransport = MCPServerTransport.stdio
    @State private var selectedClient = MCPClient.codex
    @State private var didCopyConfiguration = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Divider()
            transportPicker
            clientPicker
            recommendation
            configurationBlock

            if selectedTransport == .http {
                httpControls
            }

            footer
        }
        .padding(24)
        .frame(width: 600)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.title2)
                .foregroundStyle(selectedTransport == .stdio ? .accentColor : statusTint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text("MCP Server")
                    .font(.title2.weight(.semibold))
                Text("Copy this into your AI client to connect OpenASO tools.")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if selectedTransport == .http && controller.state.isBusy {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var transportPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connection")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            CustomSegmentedPicker(
                segments: MCPServerTransport.allCases.map { transport in
                    CustomSegmentedPicker<MCPServerTransport>.Segment(transport.title, value: transport)
                },
                selection: $selectedTransport
            )

            Text(selectedTransport.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var clientPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Client")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            CustomSegmentedPicker(
                segments: MCPClient.allCases.map { client in
                    CustomSegmentedPicker<MCPClient>.Segment(client.title, value: client)
                },
                selection: $selectedClient
            )
        }
    }

    private var recommendation: some View {
        Label {
            Text(selectedTransport.recommendation)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: selectedTransport == .stdio ? "sparkles" : "power")
        }
        .font(.caption)
        .foregroundStyle(selectedTransport == .stdio ? .primary : .secondary)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selectedTransport == .stdio ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.08))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(selectedTransport == .stdio ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12))
        }
    }

    private var configurationBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Configuration")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    copyConfiguration()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: didCopyConfiguration ? "checkmark" : "doc.on.doc")
                            .font(.caption.weight(.medium))
                            .frame(width: 14, height: 14)
                        Text(didCopyConfiguration ? "Copied" : "Copy")
                            .frame(width: 42, alignment: .leading)
                    }
                    .frame(height: 18)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Copy configuration")
            }

            ScrollView(.horizontal, showsIndicators: true) {
                Text(configurationSnippet)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, minHeight: 122, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(NSColor.textBackgroundColor).opacity(0.72))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.secondary.opacity(0.16))
            }
        }
    }

    private var httpControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(statusTitle, systemImage: statusImage)
                .font(.headline)
                .foregroundStyle(statusTint)

            VStack(alignment: .leading, spacing: 6) {
                Text("HTTP Port")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(String(settingsStore.mcpServerPort))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }

            if let endpointURL = controller.state.endpointURL {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Endpoint")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(endpointURL.absoluteString)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            Text(statusDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
    }

    private var footer: some View {
        HStack {
            Button("Close") {
                dismiss()
            }

            Spacer()

            if selectedTransport == .http {
                Button(primaryActionTitle) {
                    toggleServer()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(controller.state.isBusy)
            }
        }
    }

    private var configurationSnippet: String {
        switch (selectedClient, selectedTransport) {
        case (.codex, .stdio):
            return """
            [mcp_servers.openaso]
            enabled = true
            command = "\(Self.stdioCommand)"
            args = ["--mcp-stdio"]
            """
        case (.codex, .http):
            return """
            [mcp_servers.openaso]
            enabled = true
            url = "\(httpEndpoint)"
            """
        case (.claude, .stdio), (.antigravity, .stdio):
            return """
            {
              "mcpServers": {
                "openaso": {
                  "command": "\(Self.stdioCommand)",
                  "args": ["--mcp-stdio"]
                }
              }
            }
            """
        case (.claude, .http), (.antigravity, .http):
            return """
            {
              "mcpServers": {
                "openaso": {
                  "type": "http",
                  "url": "\(httpEndpoint)"
                }
              }
            }
            """
        case (.vsCode, .stdio):
            return """
            {
              "servers": {
                "openaso": {
                  "type": "stdio",
                  "command": "\(Self.stdioCommand)",
                  "args": ["--mcp-stdio"]
                }
              }
            }
            """
        case (.vsCode, .http):
            return """
            {
              "servers": {
                "openaso": {
                  "type": "http",
                  "url": "\(httpEndpoint)"
                }
              }
            }
            """
        }
    }

    private var httpEndpoint: String {
        controller.state.endpointURL?.absoluteString ?? "http://127.0.0.1:\(settingsStore.mcpServerPort)/mcp"
    }

    private var primaryActionTitle: String {
        switch controller.state {
        case .running, .stopping:
            return "Stop MCP Server"
        case .stopped, .starting, .failed:
            return "Start MCP Server"
        }
    }

    private var statusTitle: String {
        switch controller.state {
        case .stopped:
            return "MCP server is stopped"
        case .starting:
            return "MCP server is starting"
        case .running:
            return "MCP server is running"
        case .stopping:
            return "MCP server is stopping"
        case .failed:
            return "MCP server failed to start"
        }
    }

    private var statusDetail: String {
        switch controller.state {
        case .stopped:
            return "Ready to accept local MCP HTTP connections once started."
        case .starting:
            return "Opening a local loopback server."
        case .running(let endpointURL):
            return endpointURL.absoluteString
        case .stopping:
            return "Closing the local server."
        case .failed(let message):
            return message
        }
    }

    private var statusImage: String {
        switch controller.state {
        case .stopped:
            return "power"
        case .starting, .stopping:
            return "hourglass"
        case .running:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private var statusTint: Color {
        switch controller.state {
        case .stopped:
            return .secondary
        case .starting, .stopping:
            return .orange
        case .running:
            return .green
        case .failed:
            return .red
        }
    }

    private func toggleServer() {
        if controller.state.isRunning {
            controller.stop()
        } else {
            controller.start()
        }
    }

    private func copyConfiguration() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(configurationSnippet, forType: .string)

        didCopyConfiguration = true

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            didCopyConfiguration = false
        }
    }

    private static let stdioCommand = "/Applications/OpenASO.app/Contents/MacOS/OpenASO"
}

private enum MCPServerTransport: CaseIterable, Hashable {
    case stdio
    case http

    var title: String {
        switch self {
        case .stdio:
            return "STDIO"
        case .http:
            return "HTTP"
        }
    }

    var recommendation: String {
        switch self {
        case .stdio:
            return "Recommended. Your AI client starts OpenASO's MCP process automatically; no Start button needed."
        case .http:
            return "For clients that connect to an already-running OpenASO app. Start the server before using this URL."
        }
    }

    var description: String {
        switch self {
        case .stdio:
            return "Best for everyday use. The client launches OpenASO's MCP process when it needs tools."
        case .http:
            return "Use when a client needs a URL for an already-running OpenASO app."
        }
    }
}

private enum MCPClient: CaseIterable, Hashable {
    case codex
    case claude
    case vsCode
    case antigravity

    var title: String {
        switch self {
        case .codex:
            return "Codex"
        case .claude:
            return "Claude"
        case .vsCode:
            return "VS Code"
        case .antigravity:
            return "Antigravity"
        }
    }
}

#Preview("MCP Server Sheet") {
    let previewContainer = OpenASOPreviewContainer<Void> { _ in }
    let services = AppServices.mocked(
        httpClient: PreviewHTTPClient(),
        modelContainer: previewContainer.modelContainer
    )

    MCPServerSheet(
        controller: services.mcpServerController,
        settingsStore: services.settingsStore
    )
    .openASOPreviewEnvironment(previewContainer)
    .padding(32)
}
