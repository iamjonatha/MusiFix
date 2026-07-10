import Foundation
import Network
import OSLog

private let log = Logger(subsystem: "it.musifixapp", category: "MCPHTTPServer")

/// Server HTTP minimale su loopback (`127.0.0.1`) per il trasporto MCP
/// "Streamable HTTP". Gestisce una richiesta per connessione e delega il corpo
/// al `handler` fornito. Non è un web server generico: serve solo il singolo
/// endpoint MCP dell'app.
///
/// `@unchecked Sendable`: i tipi di Network.framework non sono `Sendable`; il
/// loro uso è confinato a una coda seriale dedicata e non attraversa mai i
/// confini di attore.
final class MCPHTTPServer: @unchecked Sendable {

    struct Request: Sendable {
        let method: String
        let path: String
        let headers: [String: String]     // chiavi in minuscolo
        let body: Data
    }

    struct Response: Sendable {
        var status: Int
        var headers: [String: String]
        var body: Data
    }

    typealias Handler = @Sendable (Request) async -> Response

    private let queue = DispatchQueue(label: "it.musifixapp.mcp.http")
    private let port: UInt16
    private let handler: Handler
    private var listener: NWListener?
    /// Connessioni in corso, trattenute finché non completano (altrimenti
    /// l'oggetto si deallocherebbe e i callback di ricezione verrebbero persi).
    private var active: [ObjectIdentifier: HTTPConnection] = [:]

    init(port: UInt16, handler: @escaping Handler) {
        self.port = port
        self.handler = handler
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Vincola il listener all'interfaccia di loopback: il server non è
        // raggiungibile dalla rete (enforcement a livello OS).
        params.requiredInterfaceType = .loopback
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NWError.posix(.EINVAL)
        }
        let l = try NWListener(using: params, on: nwPort)
        l.newConnectionHandler = { [weak self] conn in
            guard let self else { conn.cancel(); return }
            let c = HTTPConnection(conn: conn, queue: self.queue, handler: self.handler)
            let id = ObjectIdentifier(c)
            c.onClose = { [weak self] in self?.active.removeValue(forKey: id) }
            self.active[id] = c            // trattiene la connessione (accesso su `queue`)
            c.start()
        }
        l.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                log.error("Listener MCP fallito: \(error.localizedDescription)")
            }
        }
        l.start(queue: queue)
        listener = l
        log.info("Server MCP in ascolto su 127.0.0.1:\(self.port)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        queue.async { [weak self] in self?.active.removeAll() }
        log.info("Server MCP fermato")
    }
}

/// Gestione di una singola connessione HTTP: accumula i byte, individua la fine
/// degli header, legge il corpo secondo `Content-Length`, invoca il handler e
/// scrive la risposta chiudendo la connessione.
private final class HTTPConnection: @unchecked Sendable {
    private let conn: NWConnection
    private let queue: DispatchQueue
    private let handler: MCPHTTPServer.Handler
    private var buffer = Data()
    private var handled = false
    private var sentContinue = false
    private var closed = false
    /// Invocato quando la connessione ha finito, per liberarla dal server.
    var onClose: (@Sendable () -> Void)?

    init(conn: NWConnection, queue: DispatchQueue, handler: @escaping MCPHTTPServer.Handler) {
        self.conn = conn
        self.queue = queue
        self.handler = handler
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        conn.cancel()
        onClose?()
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.finish()
            default: break
            }
        }
        conn.start(queue: queue)
        receive()
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                if let req = self.parseRequest() {
                    self.dispatch(req)
                    return
                }
            }
            if isComplete || error != nil {
                self.finish()
            } else {
                self.receive()
            }
        }
    }

    /// Tenta di estrarre una richiesta completa dal buffer; nil se servono altri byte.
    /// Gestisce `Expect: 100-continue` inviando la risposta interlocutoria.
    private func parseRequest() -> MCPHTTPServer.Request? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = buffer.range(of: separator) else { return nil }
        let headerData = buffer[buffer.startIndex..<headerRange.lowerBound]
        guard let headerStr = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerStr.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerRange.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)

        // Il client (es. URLSession) può inviare gli header e attendere "100 Continue"
        // prima del corpo: rispondiamo subito, altrimenti attende all'infinito.
        if available < contentLength {
            if !sentContinue, (headers["expect"]?.lowercased().contains("100-continue") ?? false) {
                sentContinue = true
                conn.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8),
                          completion: .contentProcessed { _ in })
            }
            return nil  // corpo incompleto
        }

        let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength)
        let body = Data(buffer[bodyStart..<bodyEnd])
        return .init(method: parts[0], path: parts[1], headers: headers, body: body)
    }

    private func dispatch(_ req: MCPHTTPServer.Request) {
        guard !handled else { return }
        handled = true
        let handler = self.handler
        Task { [weak self] in
            let resp = await handler(req)
            self?.send(resp)
        }
    }

    private func send(_ resp: MCPHTTPServer.Response) {
        var head = "HTTP/1.1 \(resp.status) \(Self.reason(resp.status))\r\n"
        var headers = resp.headers
        headers["Content-Length"] = String(resp.body.count)
        headers["Connection"] = "close"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(resp.body)
        conn.send(content: out, completion: .contentProcessed { [weak self] _ in
            self?.finish()
        })
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default:  return "Status"
        }
    }
}
