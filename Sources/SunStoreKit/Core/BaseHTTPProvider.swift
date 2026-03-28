// Sources/CameraUploader/Core/BaseHTTPProvider.swift
// Swift 6.3 | HTTP 存储提供者基类（Layer 3）

import Foundation

// MARK: - HTTP 认证方式

public enum HTTPAuthentication: Sendable {
    case basic(username: String, password: String)
    case bearer(token: String)
    case custom(headers: [String: String])
    case none
}

// MARK: - HTTP 提供者配置基类

public struct HTTPProviderConfiguration: Sendable {
    public var baseURL: URL
    public var authentication: HTTPAuthentication
    public var timeoutInterval: TimeInterval
    public var allowInsecureConnection: Bool  // 用于局域网 HTTP
    public var additionalHeaders: [String: String]

    public init(
        baseURL: URL,
        authentication: HTTPAuthentication = .none,
        timeoutInterval: TimeInterval = 60,
        allowInsecureConnection: Bool = false,
        additionalHeaders: [String: String] = [:]
    ) {
        self.baseURL = baseURL
        self.authentication = authentication
        self.timeoutInterval = timeoutInterval
        self.allowInsecureConnection = allowInsecureConnection
        self.additionalHeaders = additionalHeaders
    }
}

// MARK: - BaseHTTPProvider

/// 所有基于 HTTP 的存储提供者的公共基类
open class BaseHTTPProvider: @unchecked Sendable {
    public let configuration: HTTPProviderConfiguration
    public let session: URLSession

    private let speedCalculator = SpeedCalculator()

    public init(configuration: HTTPProviderConfiguration) {
        self.configuration = configuration

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = configuration.timeoutInterval
        sessionConfig.timeoutIntervalForResource = 3600  // 1小时，针对大文件

        if configuration.allowInsecureConnection {
            // 局域网设备允许自签名证书
            self.session = URLSession(
                configuration: sessionConfig,
                delegate: SelfSignedCertificateDelegate(),
                delegateQueue: nil
            )
        } else {
            self.session = URLSession(configuration: sessionConfig)
        }
    }

    // MARK: - 公共 HTTP 工具方法

    /// 构建带认证头的 URLRequest
    public func makeRequest(url: URL, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method

        // 注入认证头
        switch configuration.authentication {
        case .basic(let username, let password):
            let credentials = "\(username):\(password)"
            if let data = credentials.data(using: .utf8) {
                request.setValue("Basic \(data.base64EncodedString())",
                                 forHTTPHeaderField: "Authorization")
            }
        case .bearer(let token):
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case .custom(let headers):
            headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        case .none:
            break
        }

        // 额外自定义头
        configuration.additionalHeaders.forEach {
            request.setValue($1, forHTTPHeaderField: $0)
        }

        return request
    }

    /// 带进度的流式上传
    public func uploadWithProgress(
        request: URLRequest,
        fileURL: URL,
        totalBytes: Int64,
        progress: (@Sendable (UploadProgress) -> Void)?
    ) async throws -> (Data, URLResponse) {
        let startTime = Date()
        var uploadedBytes: Int64 = 0

        return try await withCheckedThrowingContinuation { continuation in
            let delegate = UploadProgressDelegate(totalBytes: totalBytes) { uploaded in
                uploadedBytes = uploaded
                let elapsed = Date().timeIntervalSince(startTime)
                let speed = elapsed > 0 ? Double(uploaded) / elapsed : 0
                progress?(UploadProgress(bytesUploaded: uploaded,
                                         totalBytes: totalBytes,
                                         speed: speed))
            }

            let uploadSession = URLSession(
                configuration: .default,
                delegate: delegate,
                delegateQueue: nil
            )

            let task = uploadSession.uploadTask(with: request, fromFile: fileURL) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, let response {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: StorageError.uploadFailed(
                        reason: "Empty response", underlying: nil))
                }
            }
            task.resume()
        }
    }

    /// 将 HTTP 状态码转为 StorageError
    public func parseHTTPError(_ response: URLResponse, body: Data?) -> StorageError? {
        guard let httpResponse = response as? HTTPURLResponse else { return nil }
        switch httpResponse.statusCode {
        case 200...299: return nil
        case 401, 403:
            return .authenticationFailed("HTTP \(httpResponse.statusCode)")
        case 404:
            return .fileNotFound(path: httpResponse.url?.path ?? "unknown")
        case 409:
            return .fileAlreadyExists(path: httpResponse.url?.path ?? "unknown")
        case 507:
            return .quotaExceeded
        default:
            let reason = body.flatMap { String(data: $0, encoding: .utf8) }
                ?? "HTTP \(httpResponse.statusCode)"
            return .uploadFailed(reason: reason, underlying: nil)
        }
    }
}

// MARK: - 上传进度代理

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let totalBytes: Int64
    private let onProgress: @Sendable (Int64) -> Void

    init(totalBytes: Int64, onProgress: @escaping @Sendable (Int64) -> Void) {
        self.totalBytes = totalBytes
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        onProgress(totalBytesSent)
    }
}

// MARK: - 自签名证书代理（局域网使用）

private final class SelfSignedCertificateDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let serverTrust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// MARK: - 速度计算器

private final class SpeedCalculator: @unchecked Sendable {
    private var samples: [(timestamp: Date, bytes: Int64)] = []
    private let lock = NSLock()
    private let windowSeconds: Double = 5.0

    func update(bytes: Int64) -> Double {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        samples.append((now, bytes))
        samples.removeAll { now.timeIntervalSince($0.timestamp) > windowSeconds }

        guard samples.count >= 2 else { return 0 }
        let first = samples.first!
        let last = samples.last!
        let elapsed = last.timestamp.timeIntervalSince(first.timestamp)
        guard elapsed > 0 else { return 0 }
        return Double(last.bytes - first.bytes) / elapsed
    }
}
