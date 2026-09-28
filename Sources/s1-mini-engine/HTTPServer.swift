import Foundation
import Darwin

// --- MINIMAL OPENAI-COMPATIBLE HTTP SERVER ---
//
// Implements just enough of the OpenAI chat API to drop this model into tools
// that already speak it:
//
//   GET  /health
//   GET  /v1/models
//   POST /v1/chat/completions     stream:false -> one JSON response
//   POST /v1/chat/completions     stream:true  -> text/event-stream (SSE)
//
// Requests are handled serially on the accept loop: a llama context is not safe
// to use from two threads at once, and this is a single-user local server.
//
// Mapping rules:
//   - the LAST user message is the transcript to normalize
//   - a system message is used as the model's control line only when it starts
//     with "[" (the model's own "[Styling: ...] [Structure: ...] [Context: ...]"
//     format); anything else is ignored so ordinary assistant system prompts
//     don't corrupt the input
//   - sampling parameters (temperature/top_p/top_k) are IGNORED: the engine is
//     exact greedy, so honoring them would only break the lossless guarantee
//   - max_tokens is honored but clamped to the engine's per-request budget

func runHTTPServer(host: String, port: UInt16, modelName: String, naive: Bool) -> Never {
    let serverFD = socket(AF_INET, SOCK_STREAM, 0)
    guard serverFD >= 0 else {
        FileHandle.standardError.write(Data("Error: socket() failed\n".utf8))
        exit(1)
    }
    var reuse: Int32 = 1
    setsockopt(serverFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = host.withCString { inet_addr($0) }

    let bindRC = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            bind(serverFD, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindRC == 0 else {
        FileHandle.standardError.write(Data("Error: could not bind \(host):\(port)\n".utf8))
        exit(1)
    }
    guard listen(serverFD, 16) == 0 else {
        FileHandle.standardError.write(Data("Error: listen() failed\n".utf8))
        exit(1)
    }

    print("\(programName) server listening on http://\(host):\(port)")
    print("  POST /v1/chat/completions   GET /v1/models   GET /health")
    print("  model: \(modelName)  decoding: \(naive ? "naive" : "speculative")  input cap: \(Chunker.totalCap) chars")
    fflush(stdout)

    while true {
        var clientAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                accept(serverFD, sa, &len)
            }
        }
        if clientFD < 0 { continue }
        handleConnection(clientFD, modelName: modelName, naive: naive)
        close(clientFD)
    }
}

// MARK: - Connection handling

private struct HTTPRequest {
    let method: String
    let path: String
    var headers: [String: String] = [:]
    var body: Data = Data()
}

private struct ChatRequest: Decodable {
    struct Message: Decodable {
        struct Content: Decodable {
            let text: String
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let s = try? c.decode(String.self) {
                    self.text = s
                    return
                }
                struct Part: Decodable { let text: String? }
                let parts = try c.decode([Part].self)
                self.text = parts.compactMap { $0.text }.joined()
            }
        }
        let role: String
        let content: Content?
    }
    let model: String?
    let messages: [Message]
    let stream: Bool?
    let max_tokens: Int?

    /// The last user message is the transcript.
    var transcript: String? {
        messages.last(where: { $0.role == "user" })?.content?.text
    }
    /// A system message is a control line only when it is in the model's "[...]"
    /// format; ordinary assistant system prompts are deliberately ignored.
    var controlLine: String? {
        guard let c = messages.last(where: { $0.role == "system" })?.content?.text else { return nil }
        let trimmed = c.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("[") ? trimmed : nil
    }
}

private func handleConnection(_ fd: Int32, modelName: String, naive: Bool) {
    guard let request = readHTTPRequest(fd) else { return }

    if request.method == "OPTIONS" {
        writeResponse(fd, status: 204, reason: "No Content", contentType: "text/plain", body: Data(), extraHeaders: corsHeaders())
        return
    }

    switch (request.method, request.path) {
    case ("GET", "/health"), ("GET", "/"):
        let json = "{\"status\":\"ok\",\"model\":\"\(modelName)\"}"
        writeResponse(fd, status: 200, reason: "OK", contentType: "application/json", body: Data(json.utf8), extraHeaders: corsHeaders())
    case ("GET", "/v1/models"), ("GET", "/models"):
        let created = Int(Date().timeIntervalSince1970)
        let json = "{\"object\":\"list\",\"data\":[{\"id\":\"\(modelName)\",\"object\":\"model\",\"created\":\(created),\"owned_by\":\"local\"}]}"
        writeResponse(fd, status: 200, reason: "OK", contentType: "application/json", body: Data(json.utf8), extraHeaders: corsHeaders())
    case ("POST", "/v1/chat/completions"), ("POST", "/chat/completions"):
        handleChatCompletions(fd, request: request, modelName: modelName, naive: naive)
    default:
        sendError(fd, status: 404, message: "Not found: \(request.method) \(request.path)")
    }
}

private func handleChatCompletions(_ fd: Int32, request: HTTPRequest, modelName: String, naive: Bool) {
    guard let decoded = try? JSONDecoder().decode(ChatRequest.self, from: request.body) else {
        sendError(fd, status: 400, message: "Invalid JSON body")
        return
    }
    guard let userText = decoded.transcript else {
        sendError(fd, status: 400, message: "No user message with content found")
        return
    }
    let full = decoded.controlLine.map { $0 + "\n" + userText } ?? userText
    if full.utf8.count > Chunker.totalCap {
        sendError(fd, status: 413, message: "Input exceeds \(Chunker.totalCap) characters (got \(full.utf8.count))")
        return
    }

    // Honor the request's max_tokens, but never above the engine budget.
    let budget = min(max(decoded.max_tokens ?? maxTokens, 1), maxTokens)
    let previousMax = maxTokens
    maxTokens = budget
    defer { maxTokens = previousMax }

    let id = "chatcmpl-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let created = Int(Date().timeIntervalSince1970)

    if decoded.stream ?? false {
        streamChat(fd, id: id, created: created, modelName: modelName, text: full, naive: naive)
    } else {
        let r = enhanceLongText(full, naive: naive)
        let content = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let completionTokens = r.stats.verifiedTokens + r.stats.autoregressiveTokens
        let promptTokens = r.stats.promptTokens
        let response: [String: Any] = [
            "id": id,
            "object": "chat.completion",
            "created": created,
            "model": modelName,
            "choices": [[
                "index": 0,
                "message": ["role": "assistant", "content": content],
                "finish_reason": "stop",
            ]],
            "usage": [
                "prompt_tokens": promptTokens,
                "completion_tokens": completionTokens,
                "total_tokens": promptTokens + completionTokens,
            ],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: response)) ?? Data("{}".utf8)
        writeResponse(fd, status: 200, reason: "OK", contentType: "application/json", body: data, extraHeaders: corsHeaders())
    }
}

private func streamChat(_ fd: Int32, id: String, created: Int, modelName: String, text: String, naive: Bool) {
    var head = "HTTP/1.1 200 OK\r\n"
    head += "Content-Type: text/event-stream\r\n"
    head += "Cache-Control: no-cache\r\n"
    head += "Connection: close\r\n"
    for (k, v) in corsHeaders() { head += "\(k): \(v)\r\n" }
    head += "\r\n"
    writeAll(fd, Data(head.utf8))

    func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        var payload = Data("data: ".utf8)
        payload.append(data)
        payload.append(Data("\n\n".utf8))
        writeAll(fd, payload)
    }
    func chatChunk(_ delta: [String: Any], finish: Any) -> [String: Any] {
        [
            "id": id,
            "object": "chat.completion.chunk",
            "created": created,
            "model": modelName,
            "choices": [["index": 0, "delta": delta, "finish_reason": finish]],
        ]
    }

    send(chatChunk(["role": "assistant"], finish: NSNull()))
    _ = enhanceLongText(text, naive: naive) { piece in
        send(chatChunk(["content": piece], finish: NSNull()))
    }
    send(chatChunk([:], finish: "stop"))
    writeAll(fd, Data("data: [DONE]\n\n".utf8))
}

// MARK: - HTTP plumbing

private func corsHeaders() -> [String: String] {
    [
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers": "Content-Type, Authorization",
        "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    ]
}

private func readHTTPRequest(_ fd: Int32) -> HTTPRequest? {
    var buffer: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 8192)
    while true {
        if let end = findHeaderEnd(buffer) {
            guard let head = String(bytes: buffer[0..<end.start], encoding: .utf8) else { return nil }
            var request = parseHead(head)
            let contentLength = Int(request.headers["content-length"] ?? "0") ?? 0
            var body = Data(buffer[end.end...])
            while body.count < contentLength {
                let n = read(fd, &chunk, chunk.count)
                if n <= 0 { break }
                body.append(contentsOf: chunk[0..<n])
            }
            if body.count > contentLength { body = body.prefix(contentLength) }
            request.body = body
            return request
        }
        let n = read(fd, &chunk, chunk.count)
        if n <= 0 { return nil }
        buffer.append(contentsOf: chunk[0..<n])
        if buffer.count > 4_000_000 { return nil }
    }
}

private func findHeaderEnd(_ buffer: [UInt8]) -> (start: Int, end: Int)? {
    guard buffer.count >= 4 else { return nil }
    var i = 0
    while i <= buffer.count - 4 {
        if buffer[i] == 13 && buffer[i + 1] == 10 && buffer[i + 2] == 13 && buffer[i + 3] == 10 {
            return (i, i + 4)
        }
        i += 1
    }
    return nil
}

private func parseHead(_ head: String) -> HTTPRequest {
    let lines = head.components(separatedBy: "\r\n")
    let parts = (lines.first ?? "").split(separator: " ")
    let method = parts.count > 0 ? String(parts[0]) : ""
    var path = parts.count > 1 ? String(parts[1]) : "/"
    if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
    var request = HTTPRequest(method: method, path: path)
    for line in lines.dropFirst() {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
        let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        request.headers[key] = value
    }
    return request
}

private func sendError(_ fd: Int32, status: Int, message: String) {
    let response: [String: Any] = [
        "error": ["message": message, "type": "invalid_request_error", "code": NSNull()],
    ]
    let data = (try? JSONSerialization.data(withJSONObject: response)) ?? Data("{}".utf8)
    let reason: String
    switch status {
    case 400: reason = "Bad Request"
    case 404: reason = "Not Found"
    case 413: reason = "Payload Too Large"
    default:  reason = "Error"
    }
    writeResponse(fd, status: status, reason: reason, contentType: "application/json", body: data, extraHeaders: corsHeaders())
}

private func writeResponse(_ fd: Int32, status: Int, reason: String, contentType: String, body: Data, extraHeaders: [String: String] = [:]) {
    var head = "HTTP/1.1 \(status) \(reason)\r\n"
    head += "Content-Type: \(contentType)\r\n"
    head += "Content-Length: \(body.count)\r\n"
    head += "Connection: close\r\n"
    for (k, v) in extraHeaders { head += "\(k): \(v)\r\n" }
    head += "\r\n"
    writeAll(fd, Data(head.utf8))
    if !body.isEmpty { writeAll(fd, body) }
}

private func writeAll(_ fd: Int32, _ data: Data) {
    data.withUnsafeBytes { raw in
        guard var ptr = raw.baseAddress else { return }
        var remaining = raw.count
        while remaining > 0 {
            let n = write(fd, ptr, remaining)
            if n <= 0 { break }
            ptr = ptr.advanced(by: n)
            remaining -= n
        }
    }
}
