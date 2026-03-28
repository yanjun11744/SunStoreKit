//
//  UploadableItem.swift
//  SunStoreKit
//
//  Created by Yanjun Sun on 2026/3/28.
//

import Foundation

// MARK: - 媒体类型

public enum UploadMediaType: String, Sendable, CaseIterable {
    case photo
    case video
    case raw
    case livePhoto
    case slowMotion
    case timelapse
    case unknown

    /// 对应的 MIME Content-Type
    public var contentType: String {
        switch self {
        case .photo:                    return "image/jpeg"
        case .raw:                      return "image/x-raw"
        case .livePhoto:                return "image/heic"
        case .video, .slowMotion,
             .timelapse:               return "video/quicktime"
        case .unknown:                  return "application/octet-stream"
        }
    }
}

// MARK: - 可上传条目协议

/// 任何需要上传到远端存储的文件都实现此协议。
/// 库本身不关心文件来自 PHAsset、ICCameraFile 还是磁盘，
/// 只通过此协议取得元数据和本地文件 URL。
public protocol UploadableItem: Sendable {

    /// 全局唯一标识，用于去重和状态追踪
    var uploadItemId: String { get }

    /// 上传后的目标文件名（含扩展名）
    var filename: String { get }

    /// 媒体类型
    var mediaType: UploadMediaType { get }

    /// 文件创建时间，用于按日期归档路径策略
    var creationDate: Date { get }

    /// 预期文件大小（字节），不确定时为 nil
    var expectedFileSize: Int64? { get }

    /// 附加到上传请求的自定义元数据，默认空字典
    var uploadMetadata: [String: String] { get }

    /// 解析出可直接读取的本地文件 URL。
    /// 对于已在磁盘上的文件直接返回；
    /// 对于需要导出/下载的文件（PHAsset、ICCameraFile 等）在此完成异步操作。
    func resolveLocalURL() async throws -> URL
}

// MARK: - 协议默认实现

public extension UploadableItem {
    var expectedFileSize: Int64? { nil }
    var uploadMetadata: [String: String] { [:] }
}

// MARK: - 错误

public enum UploadableItemError: Error, Sendable {
    /// 文件已不存在或已被删除
    case fileUnavailable(id: String)
    /// 导出/下载过程失败
    case exportFailed(reason: String, underlying: (any Error)?)
    /// 操作被取消
    case cancelled
}

// MARK: - 内置实现：本地磁盘文件

/// 直接包装磁盘上已有的文件，无需任何导出操作。
public struct LocalFileUploadItem: UploadableItem {
    public let uploadItemId: String
    public let filename: String
    public let mediaType: UploadMediaType
    public let creationDate: Date
    public let expectedFileSize: Int64?
    public let uploadMetadata: [String: String]

    private let fileURL: URL

    public init(
        fileURL: URL,
        id: String? = nil,
        mediaType: UploadMediaType = .unknown,
        creationDate: Date? = nil,
        metadata: [String: String] = [:]
    ) {
        self.fileURL = fileURL
        self.filename = fileURL.lastPathComponent
        self.uploadItemId = id ?? fileURL.path
        self.mediaType = mediaType
        self.uploadMetadata = metadata

        // 从文件属性读取创建时间和大小
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        self.creationDate = creationDate
            ?? (attrs?[.creationDate] as? Date)
            ?? .now
        self.expectedFileSize = attrs?[.size] as? Int64
    }

    public func resolveLocalURL() async throws -> URL {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw UploadableItemError.fileUnavailable(id: uploadItemId)
        }
        return fileURL
    }
}

// MARK: - 内置实现：PHAsset 适配器（仅在 Photos 可用时编译）

#if canImport(Photos)
import Photos

/// 将 PHAsset 包装为 UploadableItem。
/// resolveLocalURL() 会将资产导出到临时目录后返回 URL。
public struct PHAssetUploadItem: UploadableItem {
    public let uploadItemId: String
    public let filename: String
    public let mediaType: UploadMediaType
    public let creationDate: Date
    public let expectedFileSize: Int64?
    public let uploadMetadata: [String: String]

    private let localIdentifier: String

    public init(phAsset: PHAsset) {
        self.localIdentifier = phAsset.localIdentifier
        self.uploadItemId = phAsset.localIdentifier

        let resources = PHAssetResource.assetResources(for: phAsset)
        self.filename = resources.first?.originalFilename ?? "\(phAsset.localIdentifier).jpg"

        switch phAsset.mediaType {
        case .image:
            if phAsset.mediaSubtypes.contains(.photoLive) {
                self.mediaType = .livePhoto
            } else if resources.first?.uniformTypeIdentifier.contains("raw") == true {
                self.mediaType = .raw
            } else {
                self.mediaType = .photo
            }
        case .video:
            if phAsset.mediaSubtypes.contains(.videoHighFrameRate) {
                self.mediaType = .slowMotion
            } else if phAsset.mediaSubtypes.contains(.videoTimelapse) {
                self.mediaType = .timelapse
            } else {
                self.mediaType = .video
            }
        default:
            self.mediaType = .unknown
        }

        self.creationDate = phAsset.creationDate ?? .now
        self.expectedFileSize = nil  // PHAsset 不直接暴露大小

        self.uploadMetadata = [
            "x-ph-asset-id":    phAsset.localIdentifier,
            "x-media-type":     self.mediaType.rawValue,
            "x-creation-date":  ISO8601DateFormatter().string(
                                    from: phAsset.creationDate ?? .now),
        ]
    }

    public func resolveLocalURL() async throws -> URL {
        let results = PHAsset.fetchAssets(
            withLocalIdentifiers: [localIdentifier], options: nil)
        guard let phAsset = results.firstObject else {
            throw UploadableItemError.fileUnavailable(id: uploadItemId)
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UploadService/PHAsset", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true)
        let outputURL = tempDir.appendingPathComponent(filename)

        return try await withCheckedThrowingContinuation { continuation in
            if phAsset.mediaType == .image {
                let options = PHImageRequestOptions()
                options.version = .current
                options.deliveryMode = .highQualityFormat
                options.isNetworkAccessAllowed = true

                PHImageManager.default().requestImageDataAndOrientation(
                    for: phAsset, options: options
                ) { data, _, _, _ in
                    guard let data else {
                        continuation.resume(throwing: UploadableItemError.fileUnavailable(
                            id: self.uploadItemId))
                        return
                    }
                    do {
                        try data.write(to: outputURL)
                        continuation.resume(returning: outputURL)
                    } catch {
                        continuation.resume(throwing: UploadableItemError.exportFailed(
                            reason: "写入临时文件失败", underlying: error))
                    }
                }
            } else {
                let options = PHVideoRequestOptions()
                options.version = .current
                options.deliveryMode = .highQualityFormat
                options.isNetworkAccessAllowed = true

                PHImageManager.default().requestExportSession(
                    forVideo: phAsset,
                    options: options,
                    exportPreset: AVAssetExportPresetHighestQuality
                ) { exportSession, _ in
                    guard let exportSession else {
                        continuation.resume(throwing: UploadableItemError.fileUnavailable(
                            id: self.uploadItemId))
                        return
                    }
                    exportSession.outputURL = outputURL
                    exportSession.outputFileType = .mov

                    // AVAssetExportSession 不是 Sendable，用 nonisolated(unsafe) 跨边界传递
                    // exportAsynchronously 的回调与设置在同一线程序列上，是安全的
                    nonisolated(unsafe) let safeSession = exportSession
                    let dest = outputURL
                    let itemId = self.uploadItemId
                    safeSession.exportAsynchronously {
                        switch safeSession.status {
                        case .completed:
                            continuation.resume(returning: dest)
                        case .cancelled:
                            continuation.resume(throwing: UploadableItemError.cancelled)
                        default:
                            continuation.resume(throwing: UploadableItemError.exportFailed(
                                reason: "视频导出失败 (\(itemId))",
                                underlying: safeSession.error))
                        }
                    }
                }
            }
        }
    }
}

#if canImport(AVFoundation)
import AVFoundation
#endif

#endif  // canImport(Photos)
