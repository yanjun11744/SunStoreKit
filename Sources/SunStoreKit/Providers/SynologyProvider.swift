// Sources/CameraUploader/Providers/SynologyProvider.swift
// Swift 6.3 | 群晖 Synology DSM 存储提供者

import Foundation

// MARK: - 群晖配置

public struct SynologyConfiguration: Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var password: String
    public var useHTTPS: Bool
    public var allowInsecureConnection: Bool
    public var destinationFolder: String

    public var baseURL: URL {
        let scheme = useHTTPS ? "https" : "http"
        return URL(string: "\(scheme)://\(host):\(port)")!
    }

    public init(
        host: String,
        port: Int = 5001,
        username: String,
        password: String,
        useHTTPS: Bool = true,
        allowInsecureConnection: Bool = true,
        destinationFolder: String = "/photo/camera"
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.useHTTPS = useHTTPS
        self.allowInsecureConnection = allowInsecureConnection
        self.destinationFolder = destinationFolder
    }
}

// MARK: - 群晖 API 响应

private struct SynologyAPIResponse<T: Decodable>: Decodable {
    let success: Bool
    let data: T?
    let error: SynologyAPIError?

    struct SynologyAPIError: Decodable {
        let code: Int
    }
}

private struct AuthData: Decodable {
    let sid: String
}

private struct EmptyData: Decodable {}

private struct SynologyListData: Decodable {
    let files: [SynologyFile]
    let total: Int
}

private struct SynologyFile: Decodable {
    let name: String
    let path: String
    let isdir: Bool
    let additional: AdditionalInfo?

    struct AdditionalInfo: Decodable {
        let size: Int64?
        let time: TimeInfo
    }

    struct TimeInfo: Decodable {
        let mtime: Double?
        let crtime: Double?
        let atime: Double?
    }
}

// MARK: - 群晖 Provider

public actor SynologyProvider: StorageProvider, CapableStorageProvider {
    public let id: String = "synology"
    public let displayName: String = "群晖 Synology"
    public let capabilities: StorageCapabilities = [.thumbnails, .deduplication]

    private let synologyConfig: SynologyConfiguration
    private let httpProvider: BaseHTTPProvider
    private var sessionId: String?

    private var apiBaseURL: URL {
        synologyConfig.baseURL.appendingPathComponent("/webapi/entry.cgi")
    }

    public init(configuration: SynologyConfiguration) {
        self.synologyConfig = configuration
        let httpConfig = HTTPProviderConfiguration(
            baseURL: configuration.baseURL,
            authentication: .none,
            timeoutInterval: 60,
            allowInsecureConnection: configuration.allowInsecureConnection
        )
        self.httpProvider = BaseHTTPProvider(configuration: httpConfig)
    }

    // MARK: - 认证

    private func ensureAuthenticated() async throws -> String {
        if let sid = sessionId { return sid }
        let sid = try await login()
        sessionId = sid
        return sid
    }

    private func login() async throws -> String {
        var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "api",     value: "SYNO.API.Auth"),
            URLQueryItem(name: "version", value: "7"),
            URLQueryItem(name: "method",  value: "login"),
            URLQueryItem(name: "account", value: synologyConfig.username),
            URLQueryItem(name: "passwd",  value: synologyConfig.password),
            URLQueryItem(name: "session", value: "CameraUploader"),
            URLQueryItem(name: "format",  value: "sid"),
        ]
        guard let url = components.url else {
            throw StorageError.invalidConfiguration("Cannot build auth URL")
        }

        let request = httpProvider.makeRequest(url: url)
        let (data, response) = try await httpProvider.session.data(for: request)
        if let error = httpProvider.parseHTTPError(response, body: data) { throw error }

        let decoded = try JSONDecoder().decode(SynologyAPIResponse<AuthData>.self, from: data)
        guard decoded.success, let authData = decoded.data else {
            let code = decoded.error?.code ?? -1
            throw StorageError.authenticationFailed("群晖登录失败，错误码: \(code)")
        }
        return authData.sid
    }

    public func logout() async {
        guard let sid = sessionId else { return }
        var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "api",     value: "SYNO.API.Auth"),
            URLQueryItem(name: "version", value: "7"),
            URLQueryItem(name: "method",  value: "logout"),
            URLQueryItem(name: "session", value: "CameraUploader"),
            URLQueryItem(name: "_sid",    value: sid),
        ]
        guard let url = components.url else { return }
        _ = try? await httpProvider.session.data(for: httpProvider.makeRequest(url: url))
        sessionId = nil
    }

    // MARK: - StorageProvider 实现

    public func testConnection() async throws {
        _ = try await ensureAuthenticated()
    }

    public func upload(
        _ uploadRequest: UploadRequest,
        progress: (@Sendable (UploadProgress) -> Void)?
    ) async throws -> UploadResult {
        let startTime = Date()
        let sid = try await ensureAuthenticated()

        var uploadURL = URLComponents(
            url: synologyConfig.baseURL.appendingPathComponent("/webapi/entry.cgi"),
            resolvingAgainstBaseURL: false)!
        uploadURL.queryItems = [
            URLQueryItem(name: "api",     value: "SYNO.FileStation.Upload"),
            URLQueryItem(name: "version", value: "3"),
            URLQueryItem(name: "method",  value: "upload"),
            URLQueryItem(name: "_sid",    value: sid),
        ]
        guard let url = uploadURL.url else {
            throw StorageError.invalidConfiguration("Cannot build upload URL")
        }

        let boundary = "CameraUploader_\(UUID().uuidString)"
        var request = httpProvider.makeRequest(url: url, method: "POST")
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )

        let folderPath = (uploadRequest.remotePath as NSString).deletingLastPathComponent
        let fileName   = (uploadRequest.remotePath as NSString).lastPathComponent
        let lb = "\r\n"

        var body = Data()
        func append(_ string: String) {
            body.append(string.data(using: .utf8)!)
        }

        append("--\(boundary)\(lb)")
        append("Content-Disposition: form-data; name=\"path\"\(lb)\(lb)")
        append("\(folderPath)\(lb)")

        append("--\(boundary)\(lb)")
        append("Content-Disposition: form-data; name=\"overwrite\"\(lb)\(lb)")
        append("true\(lb)")

        append("--\(boundary)\(lb)")
        append("Content-Disposition: form-data; name=\"create_parents\"\(lb)\(lb)")
        append("true\(lb)")

        append("--\(boundary)\(lb)")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\(lb)")
        append("Content-Type: \(uploadRequest.contentType)\(lb)\(lb)")

        let fileData = try Data(contentsOf: uploadRequest.localURL)
        body.append(fileData)
        append("\(lb)--\(boundary)--\(lb)")

        let fileSize = Int64(fileData.count)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try body.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let (responseData, response) = try await httpProvider.uploadWithProgress(
            request: request,
            fileURL: tempURL,
            totalBytes: fileSize,
            progress: progress
        )
        if let error = httpProvider.parseHTTPError(response, body: responseData) { throw error }

        let duration = Date().timeIntervalSince(startTime)
        let remoteInfo = RemoteFileInfo(
            path: uploadRequest.remotePath,
            name: fileName,
            size: fileSize,
            modifiedAt: .now,
            contentType: uploadRequest.contentType
        )
        return UploadResult(
            request: uploadRequest,
            remoteInfo: remoteInfo,
            duration: duration,
            averageSpeed: duration > 0 ? Double(fileSize) / duration : 0
        )
    }

    public func fileExists(at path: String) async throws -> Bool {
        let sid = try await ensureAuthenticated()
        var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "api",     value: "SYNO.FileStation.Info"),
            URLQueryItem(name: "version", value: "2"),
            URLQueryItem(name: "method",  value: "get"),
            URLQueryItem(name: "path",    value: path),
            URLQueryItem(name: "_sid",    value: sid),
        ]
        guard let url = components.url else { return false }
        let (data, response) = try await httpProvider.session.data(
            for: httpProvider.makeRequest(url: url))
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else { return false }
        let decoded = try? JSONDecoder().decode(SynologyAPIResponse<EmptyData>.self, from: data)
        return decoded?.success == true
    }

    public func listDirectory(_ path: String) async throws -> [RemoteFileInfo] {
        let sid = try await ensureAuthenticated()
        var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "api",         value: "SYNO.FileStation.List"),
            URLQueryItem(name: "version",     value: "2"),
            URLQueryItem(name: "method",      value: "list"),
            URLQueryItem(name: "folder_path", value: path),
            URLQueryItem(name: "additional",  value: "size,time,type"),
            URLQueryItem(name: "_sid",        value: sid),
        ]
        guard let url = components.url else { return [] }
        let (data, response) = try await httpProvider.session.data(
            for: httpProvider.makeRequest(url: url))
        if let error = httpProvider.parseHTTPError(response, body: data) { throw error }

        let result = try JSONDecoder().decode(SynologyAPIResponse<SynologyListData>.self, from: data)
        return result.data?.files.map { file in
            RemoteFileInfo(
                path: file.path,
                name: file.name,
                size: file.additional?.size ?? 0,
                modifiedAt: file.additional?.time.mtime
                    .flatMap { Date(timeIntervalSince1970: $0) } ?? .now,
                isDirectory: file.isdir
            )
        } ?? []
    }

    public func createDirectory(_ path: String) async throws {
        let sid = try await ensureAuthenticated()
        let parent = (path as NSString).deletingLastPathComponent
        let name   = (path as NSString).lastPathComponent
        var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "api",          value: "SYNO.FileStation.CreateFolder"),
            URLQueryItem(name: "version",      value: "2"),
            URLQueryItem(name: "method",       value: "create"),
            URLQueryItem(name: "folder_path",  value: parent),
            URLQueryItem(name: "name",         value: name),
            URLQueryItem(name: "force_parent", value: "true"),
            URLQueryItem(name: "_sid",         value: sid),
        ]
        guard let url = components.url else { return }
        let (data, response) = try await httpProvider.session.data(
            for: httpProvider.makeRequest(url: url))
        if let error = httpProvider.parseHTTPError(response, body: data) { throw error }
    }

    public func delete(at path: String) async throws {
        let sid = try await ensureAuthenticated()
        var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "api",     value: "SYNO.FileStation.Delete"),
            URLQueryItem(name: "version", value: "2"),
            URLQueryItem(name: "method",  value: "delete"),
            URLQueryItem(name: "path",    value: path),
            URLQueryItem(name: "_sid",    value: sid),
        ]
        guard let url = components.url else { return }
        let (data, response) = try await httpProvider.session.data(
            for: httpProvider.makeRequest(url: url))
        if let error = httpProvider.parseHTTPError(response, body: data) { throw error }
    }
}
