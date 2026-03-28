// Sources/CameraUploader/Core/ProviderRegistry.swift
// Swift 6.3 | 提供者注册表与工厂（Layer 2）

import Foundation

// MARK: - 提供者工厂协议

public protocol StorageProviderFactory: Sendable {
    associatedtype Configuration: Sendable
    static func make(configuration: Configuration) -> any StorageProvider
}

// MARK: - 提供者注册表

public final class StorageProviderRegistry: @unchecked Sendable {
    public static let shared = StorageProviderRegistry()

    private var providers: [String: any StorageProvider] = [:]
    private let lock = NSLock()

    private init() {}

    /// 注册提供者
    public func register(_ provider: any StorageProvider) {
        lock.lock()
        providers[provider.id] = provider
        lock.unlock()
    }

    /// 获取提供者
    public func provider(for id: String) -> (any StorageProvider)? {
        lock.lock()
        defer { lock.unlock() }
        return providers[id]
    }

    /// 所有已注册的提供者
    public var allProviders: [any StorageProvider] {
        lock.lock()
        defer { lock.unlock() }
        return Array(providers.values)
    }

    /// 测试所有提供者连接
    public func testAllConnections() async -> [String: Result<Void, StorageError>] {
        await withTaskGroup(of: (String, Result<Void, StorageError>).self) { group in
            for provider in allProviders {
                group.addTask {
                    do {
                        try await provider.testConnection()
                        return (provider.id, .success(()))
                    } catch let error as StorageError {
                        return (provider.id, .failure(error))
                    } catch {
                        return (provider.id, .failure(.unknown(error)))
                    }
                }
            }

            var results: [String: Result<Void, StorageError>] = [:]
            for await (id, result) in group {
                results[id] = result
            }
            return results
        }
    }
}

// MARK: - 快捷工厂方法

public extension StorageProviderRegistry {
    /// 注册群晖
    @discardableResult
    func registerSynology(configuration: SynologyConfiguration) -> SynologyProvider {
        let provider = SynologyProvider(configuration: configuration)
        register(provider)
        return provider
    }

    /// 注册飞牛
    @discardableResult
    func registerFeiNiu(configuration: FeiNiuConfiguration) -> FeiNiuProvider {
        let provider = FeiNiuProvider(configuration: configuration)
        register(provider)
        return provider
    }

    /// 注册 WebDAV（包括坚果云、Nextcloud、Seafile 等）
    @discardableResult
    func registerWebDAV(
        id: String, displayName: String, configuration: WebDAVConfiguration
    ) -> WebDAVProvider {
        let provider = WebDAVProvider(id: id, displayName: displayName, configuration: configuration)
        register(provider)
        return provider
    }

    /// 注册 S3
    @discardableResult
    func registerS3(
        id: String = "s3", displayName: String = "S3", configuration: S3Configuration
    ) -> S3Provider {
        let provider = S3Provider(id: id, displayName: displayName, configuration: configuration)
        register(provider)
        return provider
    }
}

// MARK: - 常见 WebDAV 服务预设

public enum WebDAVPreset {
    /// 坚果云
    public static func jianguoyun(username: String, appPassword: String) -> WebDAVConfiguration {
        WebDAVConfiguration(
            baseURL: URL(string: "https://dav.jianguoyun.com/dav/")!,
            username: username,
            password: appPassword
        )
    }

    /// Nextcloud
    public static func nextcloud(host: String, username: String, password: String) -> WebDAVConfiguration {
        let url = URL(string: "https://\(host)/remote.php/dav/files/\(username)/")!
        return WebDAVConfiguration(baseURL: url, username: username, password: password)
    }

    /// Seafile
    public static func seafile(host: String, username: String, password: String) -> WebDAVConfiguration {
        let url = URL(string: "https://\(host)/seafdav/")!
        return WebDAVConfiguration(baseURL: url, username: username, password: password)
    }

    /// ownCloud
    public static func ownCloud(host: String, username: String, password: String) -> WebDAVConfiguration {
        let url = URL(string: "https://\(host)/remote.php/webdav/")!
        return WebDAVConfiguration(baseURL: url, username: username, password: password)
    }

    /// iCloud WebDAV（通过第三方代理）
    public static func box(username: String, password: String) -> WebDAVConfiguration {
        WebDAVConfiguration(
            baseURL: URL(string: "https://dav.box.com/dav/")!,
            username: username,
            password: password
        )
    }
}
