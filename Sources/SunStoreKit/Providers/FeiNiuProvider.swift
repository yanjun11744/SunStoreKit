// Sources/CameraUploader/Providers/FeiNiuProvider.swift
// Swift 6.3 | 飞牛 NAS 存储提供者
// 飞牛 fnOS 使用标准 WebDAV 协议，同时也有自己的 API

import Foundation

// MARK: - 飞牛配置

public struct FeiNiuConfiguration: Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var password: String
    public var useHTTPS: Bool
    public var allowInsecureConnection: Bool
    public var destinationPath: String

    /// WebDAV 路径前缀（飞牛默认为 /dav/）
    public var webdavPrefix: String

    public var baseURL: URL {
        let scheme = useHTTPS ? "https" : "http"
        return URL(string: "\(scheme)://\(host):\(port)\(webdavPrefix)")!
    }

    public init(
        host: String,
        port: Int = 5005,
        username: String,
        password: String,
        useHTTPS: Bool = false,
        allowInsecureConnection: Bool = true,
        destinationPath: String = "/photos/camera",
        webdavPrefix: String = "/dav"
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.useHTTPS = useHTTPS
        self.allowInsecureConnection = allowInsecureConnection
        self.destinationPath = destinationPath
        self.webdavPrefix = webdavPrefix
    }
}

// MARK: - 飞牛 Provider
// 飞牛基于标准 WebDAV，复用 WebDAVProvider 并增加飞牛特定行为

public final class FeiNiuProvider: StorageProvider, CapableStorageProvider, @unchecked Sendable {
    public let id: String = "feiniu"
    public let displayName: String = "飞牛 fnOS"
    public let capabilities: StorageCapabilities = [.thumbnails]

    private let webdavProvider: WebDAVProvider
    private let feiNiuConfig: FeiNiuConfiguration

    public init(configuration: FeiNiuConfiguration) {
        self.feiNiuConfig = configuration

        let webdavConfig = WebDAVConfiguration(
            baseURL: configuration.baseURL,
            username: configuration.username,
            password: configuration.password,
            allowInsecureConnection: configuration.allowInsecureConnection,
            timeoutInterval: 60,
            customHeaders: [
                "X-Client": "CameraUploader/1.0",
                "Accept": "*/*"
            ]
        )
        self.webdavProvider = WebDAVProvider(
            id: "feiniu_webdav",
            displayName: "飞牛 WebDAV",
            configuration: webdavConfig
        )
    }

    // MARK: - StorageProvider 委托给 WebDAVProvider

    public func testConnection() async throws {
        try await webdavProvider.testConnection()
    }

    public func upload(
        _ request: UploadRequest,
        progress: (@Sendable (UploadProgress) -> Void)?
    ) async throws -> UploadResult {
        try await webdavProvider.upload(request, progress: progress)
    }

    public func fileExists(at path: String) async throws -> Bool {
        try await webdavProvider.fileExists(at: path)
    }

    public func listDirectory(_ path: String) async throws -> [RemoteFileInfo] {
        try await webdavProvider.listDirectory(path)
    }

    public func createDirectory(_ path: String) async throws {
        try await webdavProvider.createDirectory(path)
    }

    public func delete(at path: String) async throws {
        try await webdavProvider.delete(at: path)
    }

    // MARK: - 飞牛特有：相册触发扫描（可选调用）
    // 上传完成后通知飞牛扫描新文件（如果其提供了相关 API）

    public func triggerMediaScan(path: String) async {
        // 飞牛目前通过文件监控自动扫描，不需要手动触发
        // 预留此接口以备未来 fnOS API 支持
    }
}
