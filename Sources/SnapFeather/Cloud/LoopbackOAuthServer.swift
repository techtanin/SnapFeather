import Darwin
import Foundation

enum LoopbackOAuthError: LocalizedError {
    case socketCreationFailed
    case bindFailed
    case listenFailed
    case cancelled
    case missingAuthorizationCode
    case stateMismatch
    case authorizationDenied(String)

    var errorDescription: String? {
        switch self {
        case .socketCreationFailed:
            return "Could not open local loopback socket for Google OAuth."
        case .bindFailed:
            return "Could not bind local loopback port for Google OAuth."
        case .listenFailed:
            return "Could not listen for Google OAuth callback."
        case .cancelled:
            return "Google Drive authorization was cancelled."
        case .missingAuthorizationCode:
            return "Google OAuth callback did not contain an authorization code."
        case .stateMismatch:
            return "Google OAuth state verification failed."
        case .authorizationDenied(let message):
            return "Google Drive authorization denied: \(message)"
        }
    }
}

final class LoopbackOAuthServer: @unchecked Sendable {
    private let listenFD: Int32
    let port: UInt16
    private var isStopped = false
    private let lock = NSLock()

    init() throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw LoopbackOAuthError.socketCreationFailed
        }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // Ephemeral available port
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw LoopbackOAuthError.bindFailed
        }

        guard Darwin.listen(fd, 4) == 0 else {
            Darwin.close(fd)
            throw LoopbackOAuthError.listenFailed
        }

        var boundAddr = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.getsockname(fd, sockPtr, &boundLen)
            }
        }
        guard nameResult == 0 else {
            Darwin.close(fd)
            throw LoopbackOAuthError.bindFailed
        }

        self.listenFD = fd
        self.port = UInt16(bigEndian: boundAddr.sin_port)
    }

    var redirectURI: String {
        "http://127.0.0.1:\(port)/callback"
    }

    func waitForCallback(expectedState: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                while true {
                    lock.lock()
                    let stopped = isStopped
                    lock.unlock()
                    if stopped {
                        continuation.resume(throwing: LoopbackOAuthError.cancelled)
                        return
                    }

                    var clientAddr = sockaddr_in()
                    var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                    let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                            Darwin.accept(listenFD, sockPtr, &clientLen)
                        }
                    }

                    if clientFD < 0 {
                        lock.lock()
                        let stoppedNow = isStopped
                        lock.unlock()
                        continuation.resume(throwing: stoppedNow ? LoopbackOAuthError.cancelled : LoopbackOAuthError.cancelled)
                        return
                    }

                    var recvTimeout = timeval(tv_sec: 5, tv_usec: 0)
                    setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &recvTimeout, socklen_t(MemoryLayout<timeval>.size))

                    var buffer = [UInt8](repeating: 0, count: 8192)
                    let bytesRead = Darwin.recv(clientFD, &buffer, buffer.count, 0)
                    let requestString = bytesRead > 0
                        ? String(decoding: buffer.prefix(bytesRead), as: UTF8.self)
                        : ""

                    guard let requestLine = requestString.components(separatedBy: "\r\n").first,
                          let pathPart = requestLine.split(separator: " ").dropFirst().first else {
                        Self.sendHTTPResponse(
                            fd: clientFD,
                            status: "400 Bad Request",
                            body: Self.htmlPage(title: "Invalid Request", message: "Could not parse OAuth callback.")
                        )
                        Darwin.close(clientFD)
                        continue
                    }

                    let pathString = String(pathPart)
                    if pathString.hasPrefix("/favicon.ico") {
                        Self.sendHTTPResponse(fd: clientFD, status: "404 Not Found", body: "")
                        Darwin.close(clientFD)
                        continue
                    }

                    let components = URLComponents(string: "http://127.0.0.1:\(port)\(pathString)")
                    let queryItems = components?.queryItems ?? []
                    let errorParam = queryItems.first(where: { $0.name == "error" })?.value
                    let codeParam = queryItems.first(where: { $0.name == "code" })?.value
                    let stateParam = queryItems.first(where: { $0.name == "state" })?.value

                    if let errorParam {
                        Self.sendHTTPResponse(
                            fd: clientFD,
                            status: "200 OK",
                            body: Self.htmlPage(title: "Authorization Cancelled", message: "Google returned: \(errorParam). You may close this tab.")
                        )
                        Darwin.close(clientFD)
                        stop()
                        continuation.resume(throwing: LoopbackOAuthError.authorizationDenied(errorParam))
                        return
                    }

                    guard stateParam == expectedState else {
                        Self.sendHTTPResponse(
                            fd: clientFD,
                            status: "400 Bad Request",
                            body: Self.htmlPage(title: "State Mismatch", message: "Security state mismatch. Please retry from SnapFeather.")
                        )
                        Darwin.close(clientFD)
                        stop()
                        continuation.resume(throwing: LoopbackOAuthError.stateMismatch)
                        return
                    }

                    guard let codeParam, !codeParam.isEmpty else {
                        Self.sendHTTPResponse(
                            fd: clientFD,
                            status: "400 Bad Request",
                            body: Self.htmlPage(title: "Missing Code", message: "No authorization code was returned.")
                        )
                        Darwin.close(clientFD)
                        stop()
                        continuation.resume(throwing: LoopbackOAuthError.missingAuthorizationCode)
                        return
                    }

                    Self.sendHTTPResponse(
                        fd: clientFD,
                        status: "200 OK",
                        body: Self.htmlPage(
                            title: "Google Drive Connected",
                            message: "SnapFeather is now authorized to save screenshots to your Google Drive. You can close this browser tab."
                        )
                    )
                    Darwin.close(clientFD)
                    stop()
                    continuation.resume(returning: codeParam)
                    return
                }
            }
        }
    }

    func stop() {
        lock.lock()
        let shouldClose = !isStopped
        isStopped = true
        lock.unlock()
        if shouldClose {
            Darwin.shutdown(listenFD, SHUT_RDWR)
            Darwin.close(listenFD)
        }
    }

    private static func sendHTTPResponse(fd: Int32, status: String, body: String) {
        let bodyData = Data(body.utf8)
        let header = [
            "HTTP/1.1 \(status)",
            "Content-Type: text/html; charset=utf-8",
            "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'",
            "X-Content-Type-Options: nosniff",
            "Cache-Control: no-store",
            "Content-Length: \(bodyData.count)",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")
        var response = Data(header.utf8)
        response.append(bodyData)
        response.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = Darwin.send(fd, base, response.count, 0)
        }
    }

    static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func htmlPage(title: String, message: String) -> String {
        let safeTitle = escapeHTML(title)
        let safeMessage = escapeHTML(message)
        return """
        <!doctype html>
        <html>
        <head>
            <meta charset="utf-8">
            <title>\(safeTitle)</title>
            <style>
                body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; background: #0f172a; color: #f8fafc; display: flex; align-items: center; justify-content: center; height: 100vh; margin: 0; }
                .card { background: #1e293b; border: 1px solid rgba(255,255,255,0.12); border-radius: 16px; padding: 32px 36px; max-width: 440px; text-align: center; box-shadow: 0 20px 50px rgba(0,0,0,0.4); }
                h1 { font-size: 20px; margin: 0 0 12px; }
                p { font-size: 14px; line-height: 1.5; color: #cbd5e1; margin: 0; }
            </style>
        </head>
        <body>
            <div class="card">
                <h1>\(safeTitle)</h1>
                <p>\(safeMessage)</p>
            </div>
        </body>
        </html>
        """
    }
}
