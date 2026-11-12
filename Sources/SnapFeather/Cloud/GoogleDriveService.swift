import AppKit
import CryptoKit
import Foundation

struct DriveUploadResult: Sendable {
    let fileId: String
    let name: String
    let webViewLink: String?
}

enum GoogleDriveError: LocalizedError {
    case missingClientID
    case notAuthorized
    case invalidAuthURL
    case tokenExchangeFailed(String)
    case uploadFailed(String)
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            return "Enter your Google Cloud Desktop OAuth Client ID in Preferences > Google Drive first."
        case .notAuthorized:
            return "Google Drive is not authorized yet. Authorize it in Preferences > Google Drive."
        case .invalidAuthURL:
            return "Could not construct Google OAuth URL."
        case .tokenExchangeFailed(let details):
            return "Google OAuth token exchange failed: \(details)"
        case .uploadFailed(let details):
            return "Google Drive upload failed: \(details)"
        case .encodingFailed:
            return "Could not encode image data for Google Drive upload."
        }
    }
}

@MainActor
final class GoogleDriveService {
    static let shared = GoogleDriveService()

    private var activeServer: LoopbackOAuthServer?
    private var refreshTask: Task<String, Error>?
    private let urlSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()
    private(set) var session: GoogleDriveSession?

    private init() {
        self.session = KeychainStore.loadSession()
    }

    var isAuthorized: Bool {
        session != nil
    }

    var connectedEmail: String? {
        session?.userEmail
    }

    func cancelPendingAuthorization() {
        activeServer?.stop()
        activeServer = nil
    }

    func disconnect() {
        cancelPendingAuthorization()
        KeychainStore.deleteSession()
        session = nil
        AppPreferences.shared.googleDriveFolderID = ""
    }

    func authorize(clientID: String, clientSecret: String) async throws -> GoogleDriveSession {
        let trimmedClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedClientID.isEmpty else {
            throw GoogleDriveError.missingClientID
        }

        cancelPendingAuthorization()
        let server = try LoopbackOAuthServer()
        activeServer = server
        defer {
            server.stop()
            if activeServer === server {
                activeServer = nil
            }
        }

        let codeVerifier = Self.randomURLSafeString(byteCount: 48)
        let challengeDigest = SHA256.hash(data: Data(codeVerifier.utf8))
        let codeChallenge = Self.base64URLEncode(Data(challengeDigest))
        let state = Self.randomURLSafeString(byteCount: 24)

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: trimmedClientID),
            URLQueryItem(name: "redirect_uri", value: server.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/drive.file https://www.googleapis.com/auth/userinfo.email"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]

        guard let authURL = components.url else {
            throw GoogleDriveError.invalidAuthURL
        }

        NSWorkspace.shared.open(authURL)
        let authCode = try await server.waitForCallback(expectedState: state)

        var newSession = try await exchangeCodeForTokens(
            code: authCode,
            clientID: trimmedClientID,
            clientSecret: trimmedSecret,
            codeVerifier: codeVerifier,
            redirectURI: server.redirectURI
        )

        newSession.userEmail = await fetchUserEmail(accessToken: newSession.accessToken)
        try KeychainStore.saveSession(newSession)
        self.session = newSession
        Diagnostics.log("Google Drive authorized")
        return newSession
    }

    func uploadScreenshot(
        image: NSImage,
        format: ImageFormat,
        filename: String
    ) async throws -> DriveUploadResult {
        guard let imageData = ImageExporter.encodedData(for: image, format: format) else {
            throw GoogleDriveError.encodingFailed
        }
        return try await uploadData(imageData, mimeType: format.mimeType, filename: filename)
    }

    func uploadData(_ data: Data, mimeType: String, filename: String) async throws -> DriveUploadResult {
        let accessToken = try await ensureValidAccessToken()
        let folderID = try await resolveTargetFolderID(accessToken: accessToken)

        let metadataDict: [String: Any] = [
            "name": filename,
            "parents": [folderID]
        ]
        let metadataJSON = try JSONSerialization.data(withJSONObject: metadataDict)

        let boundary = "SnapFeatherBoundary-\(UUID().uuidString)"
        let body = Self.buildMultipartBody(
            metadata: metadataJSON,
            imageData: data,
            mimeType: mimeType,
            boundary: boundary
        )

        var request = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id,name,webViewLink")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (responseData, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GoogleDriveError.uploadFailed("Invalid HTTP response.")
        }

        // If cached folder ID was deleted externally, clear cache and retry once
        if http.statusCode == 404 {
            AppPreferences.shared.googleDriveFolderID = ""
            let freshFolderID = try await resolveTargetFolderID(accessToken: accessToken)
            let retryMeta = try JSONSerialization.data(withJSONObject: ["name": filename, "parents": [freshFolderID]])
            request.httpBody = Self.buildMultipartBody(
                metadata: retryMeta,
                imageData: data,
                mimeType: mimeType,
                boundary: boundary
            )
            let (retryData, retryResp) = try await urlSession.data(for: request)
            guard let retryHTTP = retryResp as? HTTPURLResponse, (200...299).contains(retryHTTP.statusCode) else {
                let msg = String(data: retryData, encoding: .utf8) ?? "HTTP \((retryResp as? HTTPURLResponse)?.statusCode ?? 0)"
                throw GoogleDriveError.uploadFailed(msg)
            }
            return try await finalizeUpload(responseData: retryData, accessToken: accessToken)
        }

        guard (200...299).contains(http.statusCode) else {
            let msg = String(data: responseData, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw GoogleDriveError.uploadFailed(msg)
        }

        return try await finalizeUpload(responseData: responseData, accessToken: accessToken)
    }

    private func finalizeUpload(responseData: Data, accessToken: String) async throws -> DriveUploadResult {
        struct FileResponse: Decodable {
            let id: String
            let name: String
            let webViewLink: String?
        }
        let decoded = try JSONDecoder().decode(FileResponse.self, from: responseData)

        if AppPreferences.shared.makeDriveFilesShareable {
            try? await makeFilePubliclyReadable(fileID: decoded.id, accessToken: accessToken)
        }

        return DriveUploadResult(
            fileId: decoded.id,
            name: decoded.name,
            webViewLink: decoded.webViewLink
        )
    }

    private func makeFilePubliclyReadable(fileID: String, accessToken: String) async throws {
        guard let encodedID = fileID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://www.googleapis.com/drive/v3/files/\(encodedID)/permissions") else {
            throw GoogleDriveError.uploadFailed("Invalid Drive file ID.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "role": "reader",
            "type": "anyone"
        ])
        let (_, response) = try await urlSession.data(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw GoogleDriveError.uploadFailed("Could not apply sharing permission (HTTP \(http.statusCode)).")
        }
    }

    private func ensureValidAccessToken() async throws -> String {
        if let inFlight = refreshTask {
            return try await inFlight.value
        }

        guard var current = session ?? KeychainStore.loadSession() else {
            throw GoogleDriveError.notAuthorized
        }
        session = current

        if current.expiresAt.timeIntervalSinceNow > 60 {
            return current.accessToken
        }

        guard let refreshToken = current.refreshToken, !refreshToken.isEmpty else {
            throw GoogleDriveError.notAuthorized
        }

        let prefs = AppPreferences.shared
        let clientID = prefs.googleDriveClientID
        guard !clientID.isEmpty else {
            throw GoogleDriveError.missingClientID
        }

        let task = Task<String, Error> { @MainActor [weak self] in
            guard let self else { throw GoogleDriveError.notAuthorized }
            defer { self.refreshTask = nil }

            var params = [
                "client_id": clientID,
                "refresh_token": refreshToken,
                "grant_type": "refresh_token"
            ]
            if !prefs.googleDriveClientSecret.isEmpty {
                params["client_secret"] = prefs.googleDriveClientSecret
            }

            let tokenResp = try await self.performTokenRequest(params: params)
            current.accessToken = tokenResp.accessToken
            current.expiresAt = Date().addingTimeInterval(TimeInterval(tokenResp.expiresIn))
            if let newRefresh = tokenResp.refreshToken, !newRefresh.isEmpty {
                current.refreshToken = newRefresh
            }
            try KeychainStore.saveSession(current)
            self.session = current
            return current.accessToken
        }

        self.refreshTask = task
        return try await task.value
    }

    nonisolated static func escapeDriveQueryValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }

    private func resolveTargetFolderID(accessToken: String) async throws -> String {
        let cachedID = AppPreferences.shared.googleDriveFolderID
        if !cachedID.isEmpty {
            return cachedID
        }

        let folderName = AppPreferences.shared.googleDriveFolderName
        let escapedName = Self.escapeDriveQueryValue(folderName)
        let query = "name='\(escapedName)' and mimeType='application/vnd.google-apps.folder' and trashed=false"

        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "fields", value: "files(id,name)"),
            URLQueryItem(name: "pageSize", value: "1")
        ]

        var searchReq = URLRequest(url: components.url!)
        searchReq.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (searchData, searchResp) = try await urlSession.data(for: searchReq)
        if let http = searchResp as? HTTPURLResponse, (200...299).contains(http.statusCode) {
            struct FolderList: Decodable {
                struct Folder: Decodable { let id: String }
                let files: [Folder]
            }
            if let existing = try? JSONDecoder().decode(FolderList.self, from: searchData).files.first {
                AppPreferences.shared.googleDriveFolderID = existing.id
                return existing.id
            }
        }

        // Create folder if not found
        var createReq = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files?fields=id")!)
        createReq.httpMethod = "POST"
        createReq.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        createReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        createReq.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": folderName,
            "mimeType": "application/vnd.google-apps.folder"
        ])

        let (createData, createResp) = try await urlSession.data(for: createReq)
        guard let createHTTP = createResp as? HTTPURLResponse, (200...299).contains(createHTTP.statusCode) else {
            let msg = String(data: createData, encoding: .utf8) ?? "Could not create Drive folder."
            throw GoogleDriveError.uploadFailed(msg)
        }
        struct CreatedFolder: Decodable { let id: String }
        let created = try JSONDecoder().decode(CreatedFolder.self, from: createData)
        AppPreferences.shared.googleDriveFolderID = created.id
        return created.id
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: Int
        let refreshToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
        }
    }

    private func exchangeCodeForTokens(
        code: String,
        clientID: String,
        clientSecret: String,
        codeVerifier: String,
        redirectURI: String
    ) async throws -> GoogleDriveSession {
        var params: [String: String] = [
            "code": code,
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": codeVerifier
        ]
        if !clientSecret.isEmpty {
            params["client_secret"] = clientSecret
        }

        let tokenResp = try await performTokenRequest(params: params)
        return GoogleDriveSession(
            accessToken: tokenResp.accessToken,
            refreshToken: tokenResp.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(tokenResp.expiresIn)),
            userEmail: nil
        )
    }

    private func performTokenRequest(params: [String: String]) async throws -> TokenResponse {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var components = URLComponents()
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await urlSession.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP error"
            throw GoogleDriveError.tokenExchangeFailed(msg)
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func fetchUserEmail(accessToken: String) async -> String? {
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await urlSession.data(for: req),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            return nil
        }
        struct UserInfo: Decodable { let email: String? }
        return (try? JSONDecoder().decode(UserInfo.self, from: data))?.email
    }

    nonisolated static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    nonisolated static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        if status != errSecSuccess {
            let fallback = (0..<max(1, byteCount / 16)).map { _ in UUID().uuidString }.joined()
            return base64URLEncode(Data(SHA256.hash(data: Data(fallback.utf8))))
        }
        return base64URLEncode(Data(bytes))
    }

    nonisolated static func buildMultipartBody(
        metadata: Data,
        imageData: Data,
        mimeType: String,
        boundary: String
    ) -> Data {
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
        body.append(metadata)
        body.append(Data("\r\n--\(boundary)\r\n".utf8))
        body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(imageData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }
}
