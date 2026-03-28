// Sources/CameraUploader/Providers/SynologyProvider.swift
// Swift 6.3 | 群晖 Synology DSM 存储提供者

import Foundation

// MARK: - 群晖配置

public struct SynologyConfiguration: Sendable {
    public var host: String                   // IP 或域名
    public var port: Int
    public var username: String
    public var password: String
    public var useHTTPS: Bool
    public var allowInsecureConnection: Bool  // 自签名证书
    public var destinationFolder: String      // 上传目标文件夹，如 /photo/camera

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
    let error: SynologyError?

    struct SynologyError: Decodable {
        let code: Int
    }
}

private struct AuthData: Decodable {
    let sid: String
}

private struct UploadData: Decodable {
    let blSkip: Bool?
}

// MARK: - 群晖 Provider

public final class SynologyProvider: BaseHTTPProvider, StorageProvider, CapableStorageProvider, @unchecked Sendable {
    public let id: String = "synology"
    public let displayName: String = "群晖 Synology"
    public let capabilities: StorageCapabilities = [.thumbnails, .deduplication]

    private let synologyConfig: SynologyConfiguration
    private var sessionId: String?
    private let sessionLock = NSLock()

    // DSM API 端点
    private var apiBaseURL: URL { synologyConfig.baseURL.appendingPathComponent("/webapi/entry.cgi") }

    public init(configuration: SynologyConfiguration) {
        self.synologyConfig = configuration

        let httpConfig = HTTPProviderConfiguration(
            baseURL: configuration.baseURL,
            authentication: .none,  // 群晖用自定义 token 认证
            timeoutInterval: 60,
            allowInsecureConnection: configuration.allowInsecureConnection
        )
        super.init(configuration: httpConfig)
    }

    // MARK: - 认证

    private func ensureAuthenticated() async throws -> String {
        sessionLock.lock()
        if let sid = sessionId {
            sessionLock.unlock()
            return sid
        }
        sessionLock.unlock()

        let sid = try await login()
        sessionLock.lock()
        sessionId = sid
        sessionLock.unlock()
        return sid
    }

    private func login() async throws -> String {
        var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "api", value: "SYNO.API.Auth"),
            URLQueryItem(name: "version", value: "7"),
            URLQueryItem(name: "method", value: "login"),
            URLQueryItem(name: "account", value: synologyConfig.username),
            URLQueryItem(name: "passwd", value: synologyConfig.password),
            URLQueryItem(name: "session", value: "CameraUploader"),
            URLQueryItem(name: "format", value: "sid"),
        ]

        guard let url = components.url else {
            throw StorageError.invalidConfiguration("Cannot build auth URL")
        }

        let request = makeRequest(url: url)
        let (data, response) = try await session.data(for: request)
        if let error = parseHTTPError(response, body: data) { throw error }

        let decoded = try JSONDecoder().decode(SynologyAPIResponse<AuthData>.self, from: data)
        guard decoded.success, let authData = decoded.data else {
            let code = decoded.error?.code ?? -1
            throw StorageError.authenticationFailed("群晖登录失败，错误码: \(code)")
        }
        return authData.sid
    }

    private func logout() async {
        guard let sid = sessionId else { return }
        var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "api", value: "SYNO.API.Auth"),
            URLQueryItem(name: "version", value: "7"),
            URLQueryItem(name: "method", value: "logout"),
            URLQueryItem(name: "session", value: "CameraUploader"),
            URLQueryItem(name: "_sid", value: sid),
        ]
        guard let url = components.url else { return }
        _ = try? await session.data(for: makeRequest(url: url))
        sessionLock.lock()
        sessionId = nil
        sessionLock.unlock()
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

        // 群晖 FileStation Upload API
        var uploadURL = URLComponents(url: synologyConfig.baseURL.appendingPathComponent("/webapi/entry.cgi"),
                                       resolvingAgainstBaseURL: false)!
        uploadURL.queryItems = [
            URLQueryItem(name: "api", value: "SYNO.FileStation.Upload"),
            URLQueryItem(name: "version", value: "3"),
            URLQueryItem(name: "method", value: "upload"),
            URLQueryItem(name: "_sid", value: sid),
        ]

        guard let url = uploadURL.url else {
            throw StorageError.invalidConfiguration("Cannot build upload URL")
        }

        // multipart/form-data 上传
        let boundary = "CameraUploader_\(UUID().uuidString)"
        var request = makeRequest(url: url, method: "POST")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let folderPath = (uploadRequest.remotePath as NSString).deletingLastPathComponent
        let fileName = (uploadRequest.remotePath as NSString).lastPathComponent

        // 构建 multipart body
        var body = Data()
        let lineBreak = "\r\n"

        func append(_ string: String) {
            body.append(string.data(using: .utf8)!)
        }

        // path 字段
        append("--\(boundary)\(lineBreak)")
        append("Content-Disposition: form-data; name=\"path\"\(lineBreak)\(lineBreak)")
        append(folderPath + lineBreak)

        // overwrite 字段
        append("--\(boundary)\(lineBreak)")
        append("Content-Disposition: form-data; name=\"overwrite\"\(lineBreak)\(lineBreak)")
        append("true\(lineBreak)")

        // create_parents 字段
        append("--\(boundary)\(lineBreak)")
        append("Content-Disposition: form-data; name=\"create_parents\"\(lineBreak)\(lineBreak)")
        append("true\(lineBreak)")

        // 文件字段
        append("--\(boundary)\(lineBreak)")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\(lineBreak)")
        append("Content-Type: \(uploadRequest.contentType)\(lineBreak)\(lineBreak)")

        let fileData = try Data(contentsOf: uploadRequest.localURL)
        body.append(fileData)
        append("\(lineBreak)--\(boundary)--\(lineBreak)")

        // 获取文件大小
        let fileSize = Int64(fileData.count)

        // 通过临时文件上传（支持进度）
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try body.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let (responseData, response) = try await uploadWithProgress(
            request: request,
            fileURL: tempURL,
            totalBytes: fileSize,
            progress: progress
        )

        if let error = parseHTTPError(response, body: responseData) { throw error }

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
            URLQueryItem(name: "api", value: "SYNO.FileStation.Info"),
            URLQueryItem(name: "version", value: "2"),
            URLQueryItem(name: "method", value: "get"),
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "_sid", value: sid),
        ]
        guard let url = components.url else { return false }
        let (data, response) = try await session.data(for: makeRequest(url: url))
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else { return false }
        let decoded = try? JSONDecoder().decode(SynologyAPIResponse<EmptyData>.self, from: data)
        return decoded?.success == true
    }

    public func listDirectory(_ path: String) async throws -> [RemoteFileInfo] {
        let sid = try await ensureAuthenticated()
        var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "api", value: "SYNO.FileStation.List"),
            URLQueryItem(name: "version", value: "2"),
            URLQueryItem(name: "method", value: "list"),
            URLQueryItem(name: "folder_path", value: path),
            URLQueryItem(name: "additional", value: "size,time,type"),
            URLQueryItem(name: "_sid", value: sid),
        ]
        guard let url = components.url else { return [] }
        let (data, response) = try await session.data(for: makeRequest(url: url))
        if let error = parseHTTPError(response, body: data) { throw error }

        let decoder = JSONDecoder()
        let result = try decoder.decode(SynologyAPIResponse<SynologyListData>.self, from: data)
        return result.data?.files.map { file in
            RemoteFileInfo(
                path: file.path,
                name: file.name,
                size: file.additional?.size ?? 0,
                modifiedAt: file.additional?.time.mtime.flatMap { Date(timeIntervalSince1970: $0) } ?? .now,
                isDirectory: file.isdir
            )
        } ?? []
    }

    public func createDirectory(_ path: String) async throws {
        let sid = try await ensureAuthenticated()
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "api", value: "SYNO.FileStation.CreateFolder"),
            URLQueryItem(name: "version", value: "2"),
            URLQueryItem(name: "method", value: "create"),
            URLQueryItem(name: "folder_path", value: parent),
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "force_parent", value: "true"),
            URLQueryItem(name: "_sid", value: sid),
        ]
        guard let url = components.url else { return }
        let (data, response) = try await session.data(for: makeRequest(url: url))
        if let error = parseHTTPError(response, body: data) { throw error }
    }

    public func delete(at path: String) async throws {
        let sid = try await ensureAuthenticated()
        var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "api", value: "SYNO.FileStation.Delete"),
            URLQueryItem(name: "version", value: "2"),
            URLQueryItem(name: "method", value: "delete"),
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "_sid", value: sid),
        ]
        guard let url = components.url else { return }
        let (data, response) = try await session.data(for: makeRequest(url: url))
        if let error = parseHTTPError(response, body: data) { throw error }
    }
}

// MARK: - 群晖响应数据结构

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
