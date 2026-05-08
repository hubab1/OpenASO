import Foundation
import MCP
import Network
import Observation

@Observable
@MainActor
final class OpenASOMCPServerController {
    enum State: Equatable {
        case stopped
        case starting
        case running(URL)
        case stopping
        case failed(String)

        var isRunning: Bool {
            if case .running = self {
                return true
            }
            return false
        }

        var isBusy: Bool {
            switch self {
            case .starting, .stopping:
                return true
            case .stopped, .running, .failed:
                return false
            }
        }

        var endpointURL: URL? {
            if case .running(let url) = self {
                return url
            }
            return nil
        }
    }

    private let portProvider: @MainActor () -> Int
    private let makeServer: @MainActor () async throws -> Server
    private var localServer: OpenASOMCPLocalHTTPServer?

    private(set) var state: State = .stopped

    init(
        portProvider: @escaping @MainActor () -> Int = { MCPServerPort.defaultValue },
        makeServer: @escaping @MainActor () async throws -> Server
    ) {
        self.portProvider = portProvider
        self.makeServer = makeServer
    }

    func start() {
        guard !state.isBusy, !state.isRunning else {
            return
        }

        state = .starting
        Task { @MainActor in
            do {
                let port = portProvider()
                let localServer = try await OpenASOMCPLocalHTTPServer.start(
                    makeServer: makeServer,
                    port: port
                )
                self.localServer = localServer
                self.state = .running(localServer.endpointURL)
            } catch {
                self.localServer = nil
                self.state = .failed(OpenASOError.map(error).localizedDescription)
            }
        }
    }

    func stop() {
        guard !state.isBusy else {
            return
        }

        guard let localServer else {
            state = .stopped
            return
        }

        state = .stopping
        Task { @MainActor in
            await localServer.stop()
            self.localServer = nil
            self.state = .stopped
        }
    }
}

private actor OpenASOMCPLocalHTTPServer {
    private struct MCPSession {
        let server: Server
        let transport: StatefulHTTPServerTransport
    }

    nonisolated let endpointURL: URL

    private let makeServer: @MainActor () async throws -> Server
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.thirdtech.openaso.mcp.http")
    private var sessions: [String: MCPSession] = [:]

    private init(
        makeServer: @escaping @MainActor () async throws -> Server,
        listener: NWListener,
        endpointURL: URL
    ) {
        self.makeServer = makeServer
        self.listener = listener
        self.endpointURL = endpointURL
    }

    static func start(
        makeServer: @escaping @MainActor () async throws -> Server,
        port: Int
    ) async throws -> OpenASOMCPLocalHTTPServer {
        guard (MCPServerPort.minimum...MCPServerPort.maximum).contains(port),
              let rawPort = UInt16(exactly: port),
              let endpointPort = NWEndpoint.Port(rawValue: rawPort)
        else {
            throw OpenASOError.providerUnavailable("MCP server port \(port) is outside the supported port range \(MCPServerPort.minimum)-\(MCPServerPort.maximum).")
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: endpointPort)

        do {
            let listener = try NWListener(using: parameters)
            return try await startListener(
                listener,
                makeServer: makeServer,
                port: rawPort
            )
        } catch {
            if let openASOError = error as? OpenASOError {
                throw openASOError
            }
            throw bindError(for: port, underlying: error)
        }
    }

    private static func startListener(
        _ listener: NWListener,
        makeServer: @escaping @MainActor () async throws -> Server,
        port: UInt16
    ) async throws -> OpenASOMCPLocalHTTPServer {
        try await withCheckedThrowingContinuation { continuation in
            let box = StartContinuationBox(continuation)
            let handlerBox = LocalServerHandlerBox()

            listener.newConnectionHandler = { connection in
                Task {
                    await handlerBox.handle(connection)
                }
            }

            listener.stateUpdateHandler = { state in
                Task {
                    switch state {
                    case .ready:
                        guard let listenerPort = listener.port else {
                            await box.resume(throwing: OpenASOError.providerUnavailable("MCP server started without a TCP port."))
                            return
                        }

                        guard listenerPort.rawValue == port else {
                            await box.resume(throwing: OpenASOError.providerUnavailable("MCP server started on port \(listenerPort.rawValue) instead of configured port \(port)."))
                            return
                        }

                        guard let endpointURL = URL(string: "http://127.0.0.1:\(listenerPort.rawValue)/mcp") else {
                            await box.resume(throwing: OpenASOError.providerUnavailable("MCP server produced an invalid endpoint."))
                            return
                        }

                        let localServer = OpenASOMCPLocalHTTPServer(
                            makeServer: makeServer,
                            listener: listener,
                            endpointURL: endpointURL
                        )
                        await handlerBox.set(localServer)
                        await box.resume(returning: localServer)

                    case .failed(let error):
                        await box.resume(throwing: bindError(for: Int(port), underlying: error))

                    case .cancelled:
                        await box.resume(throwing: OpenASOError.providerUnavailable("MCP server was cancelled before it started."))

                    case .setup, .waiting:
                        break

                    @unknown default:
                        break
                    }
                }
            }

            listener.start(queue: DispatchQueue(label: "com.thirdtech.openaso.mcp.listener"))
        }
    }

    private nonisolated static func bindError(for port: Int, underlying error: any Error) -> OpenASOError {
        OpenASOError.providerUnavailable(
            "MCP server could not bind to port \(port). Choose a different port in Settings or stop the process already using it. \(error.localizedDescription)"
        )
    }

    func stop() async {
        listener.cancel()
        for session in sessions.values {
            await session.server.stop()
        }
        sessions.removeAll()
    }

    fileprivate func handle(connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            if case .failed = state {
                connection.cancel()
            }
        }
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task {
                await self.processReceivedData(
                    data,
                    isComplete: isComplete,
                    error: error,
                    on: connection,
                    buffer: buffer
                )
            }
        }
    }

    private func processReceivedData(
        _ data: Data?,
        isComplete: Bool,
        error: (any Error)?,
        on connection: NWConnection,
        buffer: Data
    ) async {
        if error != nil || isComplete {
            connection.cancel()
            return
        }

        var nextBuffer = buffer
        if let data {
            nextBuffer.append(data)
        }

        do {
            if let request = try Self.parseRequest(from: nextBuffer) {
                let response = await handle(request: request)
                send(response: response, on: connection)
            } else {
                receiveRequest(on: connection, buffer: nextBuffer)
            }
        } catch {
            send(
                response: .error(statusCode: 400, .invalidRequest(error.localizedDescription)),
                on: connection
            )
        }
    }

    private func handle(request: HTTPRequest) async -> HTTPResponse {
        do {
            let normalizedRequest = Self.normalizedAcceptHeaderRequest(request)

            if Self.isInitializeRequest(normalizedRequest) {
                return try await handleInitializeRequest(normalizedRequest)
            }

            guard let sessionID = normalizedRequest.header(HTTPHeaderName.sessionID) else {
                return .error(
                    statusCode: 400,
                    .invalidRequest("Bad Request: Missing \(HTTPHeaderName.sessionID) header")
                )
            }

            guard let session = sessions[sessionID] else {
                return .error(
                    statusCode: 404,
                    .invalidRequest("Not Found: Invalid or expired session ID")
                )
            }

            let response = await session.transport.handleRequest(normalizedRequest)
            if normalizedRequest.method.uppercased() == "DELETE" {
                await session.server.stop()
                sessions.removeValue(forKey: sessionID)
            }
            return response
        } catch {
            return .error(
                statusCode: 500,
                .internalError("MCP request failed: \(OpenASOError.map(error).localizedDescription)")
            )
        }
    }

    private func handleInitializeRequest(_ request: HTTPRequest) async throws -> HTTPResponse {
        let server = try await makeServer()
        let transport = StatefulHTTPServerTransport()
        try await server.start(transport: transport)

        let response = await transport.handleRequest(request)
        if let sessionID = response.headers[HTTPHeaderName.sessionID] {
            sessions[sessionID] = MCPSession(server: server, transport: transport)
        } else {
            await server.stop()
        }
        return response
    }

    private static func isInitializeRequest(_ request: HTTPRequest) -> Bool {
        guard
            request.method.uppercased() == "POST",
            let body = request.body,
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let method = json["method"] as? String
        else {
            return false
        }

        return method == "initialize"
    }

    private static func normalizedAcceptHeaderRequest(_ request: HTTPRequest) -> HTTPRequest {
        let requiredTypes: [String]
        switch request.method.uppercased() {
        case "POST":
            requiredTypes = ["application/json", "text/event-stream"]
        case "GET":
            requiredTypes = ["text/event-stream"]
        default:
            return request
        }

        let acceptHeader = request.headers.first {
            $0.key.caseInsensitiveCompare(HTTPHeaderName.accept) == .orderedSame
        }
        let acceptHeaderName = acceptHeader?.key ?? HTTPHeaderName.accept
        let acceptTypes = (acceptHeader?.value ?? "").split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }

        var normalizedTypes = acceptTypes
        for requiredType in requiredTypes where !normalizedTypes.contains(where: { $0.hasPrefix(requiredType) }) {
            normalizedTypes.append(requiredType)
        }

        var headers = request.headers
        headers[acceptHeaderName] = normalizedTypes.joined(separator: ", ")
        return HTTPRequest(
            method: request.method,
            headers: headers,
            body: request.body,
            path: request.path
        )
    }

    private func send(response: HTTPResponse, on connection: NWConnection) {
        if case .stream(let stream, let headers) = response {
            send(stream: stream, headers: headers, statusCode: response.statusCode, on: connection)
            return
        }

        let body = response.bodyData ?? Data()
        var headers = response.headers
        headers["Content-Length"] = "\(body.count)"
        headers["Connection"] = "close"

        if body.isEmpty {
            headers["Content-Type"] = headers["Content-Type"] ?? "text/plain"
        }

        let statusLine = "HTTP/1.1 \(response.statusCode) \(Self.reasonPhrase(for: response.statusCode))"
        let headerLines = headers
            .map { "\($0.key): \($0.value)" }
            .sorted()
            .joined(separator: "\r\n")
        var payload = Data("\(statusLine)\r\n\(headerLines)\r\n\r\n".utf8)
        payload.append(body)

        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func send(
        stream: AsyncThrowingStream<Data, any Error>,
        headers: [String: String],
        statusCode: Int,
        on connection: NWConnection
    ) {
        let statusLine = "HTTP/1.1 \(statusCode) \(Self.reasonPhrase(for: statusCode))"
        let headerLines = headers
            .map { "\($0.key): \($0.value)" }
            .sorted()
            .joined(separator: "\r\n")
        let payload = Data("\(statusLine)\r\n\(headerLines)\r\n\r\n".utf8)

        connection.send(content: payload, completion: .contentProcessed { [weak self] error in
            guard error == nil else {
                connection.cancel()
                return
            }

            Task {
                await self?.send(stream: stream, on: connection)
            }
        })
    }

    private func send(stream: AsyncThrowingStream<Data, any Error>, on connection: NWConnection) async {
        do {
            for try await chunk in stream {
                try await send(chunk: chunk, on: connection)
            }
        } catch {
            connection.cancel()
            return
        }

        connection.cancel()
    }

    private nonisolated func send(chunk: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: chunk, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private static func parseRequest(from data: Data) throws -> HTTPRequest? {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }

        let headerData = data[..<headerRange.lowerBound]
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            throw OpenASOError.providerUnavailable("MCP HTTP request headers were not valid UTF-8.")
        }

        var lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw OpenASOError.providerUnavailable("MCP HTTP request was empty.")
        }
        lines.removeFirst()

        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count >= 2 else {
            throw OpenASOError.providerUnavailable("MCP HTTP request line was invalid.")
        }

        var headers: [String: String] = [:]
        for line in lines {
            guard let separatorIndex = line.firstIndex(of: ":") else {
                continue
            }
            let name = String(line[..<separatorIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: separatorIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }

        let contentLength = Int(headers.first { $0.key.caseInsensitiveCompare("Content-Length") == .orderedSame }?.value ?? "0") ?? 0
        let bodyStart = headerRange.upperBound
        let requiredLength = bodyStart + contentLength
        guard data.count >= requiredLength else {
            return nil
        }

        let body = contentLength > 0 ? Data(data[bodyStart..<requiredLength]) : nil
        return HTTPRequest(
            method: requestParts[0],
            headers: headers,
            body: body,
            path: requestParts[1]
        )
    }

    private static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 421: "Misdirected Request"
        case 500: "Internal Server Error"
        default: "HTTP Status"
        }
    }
}

private actor LocalServerHandlerBox {
    private var server: OpenASOMCPLocalHTTPServer?

    func set(_ server: OpenASOMCPLocalHTTPServer) {
        self.server = server
    }

    func handle(_ connection: NWConnection) {
        guard let server else {
            connection.cancel()
            return
        }

        Task {
            await server.handle(connection: connection)
        }
    }
}

private actor StartContinuationBox {
    private var continuation: CheckedContinuation<OpenASOMCPLocalHTTPServer, any Error>?

    init(_ continuation: CheckedContinuation<OpenASOMCPLocalHTTPServer, any Error>) {
        self.continuation = continuation
    }

    func resume(returning server: OpenASOMCPLocalHTTPServer) {
        take()?.resume(returning: server)
    }

    func resume(throwing error: any Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<OpenASOMCPLocalHTTPServer, any Error>? {
        let continuation = continuation
        self.continuation = nil
        return continuation
    }
}
