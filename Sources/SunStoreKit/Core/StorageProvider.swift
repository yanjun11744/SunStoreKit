// Sources/CameraUploader/Core/StorageProvider.swift
// Swift 6.3 | 分层抽象核心协议

import Foundation

// MARK: - 上传进度

public struct UploadProgress: Sendable {
    public let bytesUploaded: Int64
    public let totalBytes: Int64
    public let fractionCompleted: Double
    public let speed: Double          // bytes/sec
    public let estimatedTimeRemaining: TimeInterval?

    public init(bytesUploaded: Int64, totalBytes: Int64, speed: Double = 0) {
        self.bytesUploaded = bytesUploaded
        self.totalBytes = totalBytes
        self.fractionCompleted = totalBytes > 0 ? Double(bytesUploaded) / Double(totalBytes) : 0
        self.speed = speed
        self.estimatedTimeRemaining = speed > 0 && totalBytes > bytesUploaded
            ? Double(totalBytes - bytesUploaded) / speed
            : nil
    }
}

// MARK: - 远端文件信息

public struct RemoteFileInfo: Sendable {
    public let path: String
    public let name: String
    public let size: Int64
    public let modifiedAt: Date
    public let etag: String?
    public let contentType: String?
    public let isDirectory: Bool

    public init(
        path: String, name: String, size: Int64,
        modifiedAt: Date, etag: String? = nil,
        contentType: String? = nil, isDirectory: Bool = false
    ) {
        self.path = path
        self.name = name
        self.size = size
        self.modifiedAt = modifiedAt
        self.etag = etag
        self.contentType = contentType
        self.isDirectory = isDirectory
    }
}

// MARK: - 上传请求

public struct UploadRequest: Sendable {
    public let localURL: URL
    public let remotePath: String          // 目标路径（含文件名）
    public let contentType: String
    public let metadata: [String: String]
    public let overwritePolicy: OverwritePolicy

    public enum OverwritePolicy: Sendable {
        case overwrite
        case skip
        case rename(suffix: String = " (copy)")
        case fail
    }

    public init(
        localURL: URL,
        remotePath: String,
        contentType: String = "application/octet-stream",
        metadata: [String: String] = [:],
        overwritePolicy: OverwritePolicy = .overwrite
    ) {
        self.localURL = localURL
        self.remotePath = remotePath
        self.contentType = contentType
        self.metadata = metadata
        self.overwritePolicy = overwritePolicy
    }
}

// MARK: - 上传结果

public struct UploadResult: Sendable {
    public let request: UploadRequest
    public let remoteInfo: RemoteFileInfo
    public let duration: TimeInterval
    public let averageSpeed: Double        // bytes/sec

    public init(request: UploadRequest, remoteInfo: RemoteFileInfo,
                duration: TimeInterval, averageSpeed: Double) {
        self.request = request
        self.remoteInfo = remoteInfo
        self.duration = duration
        self.averageSpeed = averageSpeed
    }
}

// MARK: - 存储错误

public enum StorageError: Error, Sendable {
    case authenticationFailed(String)
    case connectionFailed(underlying: any Error)
    case fileNotFound(path: String)
    case permissionDenied(path: String)
    case quotaExceeded
    case fileAlreadyExists(path: String)
    case invalidConfiguration(String)
    case uploadFailed(reason: String, underlying: (any Error)?)
    case checksumMismatch(expected: String, actual: String)
    case unsupportedOperation(String)
    case cancelled
    case unknown(any Error)
}

// MARK: - 核心存储协议（Layer 1）

/// 最底层协议：所有存储后端必须实现
public protocol StorageProvider: Sendable {
    /// 提供者唯一标识符
    var id: String { get }

    /// 显示名称
    var displayName: String { get }

    /// 连接测试
    func testConnection() async throws

    /// 上传单个文件，支持进度回调
    func upload(
        _ request: UploadRequest,
        progress: (@Sendable (UploadProgress) -> Void)?
    ) async throws -> UploadResult

    /// 检查文件是否存在
    func fileExists(at path: String) async throws -> Bool

    /// 列出目录内容
    func listDirectory(_ path: String) async throws -> [RemoteFileInfo]

    /// 创建目录（递归）
    func createDirectory(_ path: String) async throws

    /// 删除远端文件
    func delete(at path: String) async throws
}

// MARK: - 断点续传协议（Layer 1 扩展）

public protocol ResumableStorageProvider: StorageProvider {
    /// 初始化分片上传，返回 uploadId
    func initiateMultipartUpload(
        remotePath: String,
        contentType: String,
        metadata: [String: String]
    ) async throws -> String

    /// 上传分片
    func uploadPart(
        uploadId: String,
        remotePath: String,
        partNumber: Int,
        data: Data
    ) async throws -> String  // 返回 ETag

    /// 完成分片上传
    func completeMultipartUpload(
        uploadId: String,
        remotePath: String,
        parts: [(partNumber: Int, etag: String)]
    ) async throws -> UploadResult

    /// 取消分片上传
    func abortMultipartUpload(uploadId: String, remotePath: String) async throws
}

// MARK: - 存储能力描述

public struct StorageCapabilities: Sendable, OptionSet {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }

    public static let multipartUpload   = StorageCapabilities(rawValue: 1 << 0)
    public static let serverSideEncrypt = StorageCapabilities(rawValue: 1 << 1)
    public static let versioning        = StorageCapabilities(rawValue: 1 << 2)
    public static let presignedURL      = StorageCapabilities(rawValue: 1 << 3)
    public static let thumbnails        = StorageCapabilities(rawValue: 1 << 4)
    public static let deduplication     = StorageCapabilities(rawValue: 1 << 5)
}

public protocol CapableStorageProvider: StorageProvider {
    var capabilities: StorageCapabilities { get }
}

extension StorageError: Equatable {
    public static func == (lhs: StorageError, rhs: StorageError) -> Bool {
        switch (lhs, rhs) {
        case (.authenticationFailed(let a), .authenticationFailed(let b)): return a == b
        case (.fileNotFound(let a), .fileNotFound(let b)): return a == b
        case (.permissionDenied(let a), .permissionDenied(let b)): return a == b
        case (.quotaExceeded, .quotaExceeded): return true
        case (.fileAlreadyExists(let a), .fileAlreadyExists(let b)): return a == b
        case (.invalidConfiguration(let a), .invalidConfiguration(let b)): return a == b
        case (.uploadFailed(let a, _), .uploadFailed(let b, _)): return a == b
        case (.checksumMismatch(let a1, let a2), .checksumMismatch(let b1, let b2)): return a1 == b1 && a2 == b2
        case (.unsupportedOperation(let a), .unsupportedOperation(let b)): return a == b
        case (.cancelled, .cancelled): return true
        // Error 类型无法通用比较，降级为 false
        case (.connectionFailed, .connectionFailed): return false
        case (.unknown, .unknown): return false
        default: return false
        }
    }
}
