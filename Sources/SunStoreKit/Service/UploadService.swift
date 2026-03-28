//
//  UploadService.swift
//  通用上传服务（顶层编排器）
//
//  Created by Yanjun Sun on 2026/3/28.
//

import Foundation

// MARK: - 服务配置

public struct UploadServiceConfiguration: Sendable {

    /// 上传根目录，所有路径策略的 baseFolder
    public var baseFolder: String

    /// 远端路径策略，默认按日期归档
    public var pathStrategy: any RemotePathStrategy

    /// 上传队列配置
    public var queueConfig: UploadQueue.Configuration

    /// 允许上传的媒体类型，默认全部
    public var allowedMediaTypes: Set<UploadMediaType>

    /// 单文件最大字节数，nil 表示不限
    public var maxFileSizeBytes: Int64?

    /// 是否跳过已上传过的条目（基于 uploadItemId）
    public var skipAlreadyUploaded: Bool

    /// 上传完成后是否删除临时导出的本地文件
    public var cleanupTempFiles: Bool

    public init(
        baseFolder: String = "/uploads",
        pathStrategy: any RemotePathStrategy = DateOrganizedPathStrategy(),
        queueConfig: UploadQueue.Configuration = .init(),
        allowedMediaTypes: Set<UploadMediaType> = Set(UploadMediaType.allCases),
        maxFileSizeBytes: Int64? = nil,
        skipAlreadyUploaded: Bool = true,
        cleanupTempFiles: Bool = true
    ) {
        self.baseFolder = baseFolder
        self.pathStrategy = pathStrategy
        self.queueConfig = queueConfig
        self.allowedMediaTypes = allowedMediaTypes
        self.maxFileSizeBytes = maxFileSizeBytes
        self.skipAlreadyUploaded = skipAlreadyUploaded
        self.cleanupTempFiles = cleanupTempFiles
    }
}

// MARK: - 上传统计

public struct UploadServiceStatistics: Sendable {
    public var totalUploaded: Int    = 0
    public var totalFailed: Int      = 0
    public var totalSkipped: Int     = 0
    public var totalBytesUploaded: Int64 = 0
    public var lastUploadDate: Date? = nil
    public var averageSpeedBytesPerSec: Double = 0

    public var totalProcessed: Int { totalUploaded + totalFailed + totalSkipped }
}

// MARK: - 过滤结果（方便调用方知道为何跳过）

public enum ItemFilterResult: Sendable {
    case accepted
    case skippedMediaType(UploadMediaType)
    case skippedFileSize(Int64)
    case skippedAlreadyUploaded(remotePath: String)
}

// MARK: - UploadService

/// 通用上传服务。
/// 不关心文件来自相机、相册还是磁盘——只要实现 `UploadableItem` 协议即可上传。
///
/// 典型用法：
/// ```swift
/// let service = UploadService(provider: synologyProvider)
///
/// // 上传单个条目
/// let task = try await service.upload(item: photoItem)
///
/// // 批量上传
/// let tasks = try await service.upload(items: selectedItems)
///
/// // 观察进度
/// for await state in task.stateStream() {
///     print(state)
/// }
/// ```
public actor UploadService {

    // MARK: - 属性

    private let provider: any StorageProvider
    private let configuration: UploadServiceConfiguration
    private let queue: UploadQueue
    private let uploadedStore: UploadedItemStore

    public private(set) var statistics = UploadServiceStatistics()

    // MARK: - 初始化

    public init(
        provider: any StorageProvider,
        configuration: UploadServiceConfiguration = .init()
    ) {
        self.provider = provider
        self.configuration = configuration
        self.queue = UploadQueue(
            provider: provider,
            configuration: configuration.queueConfig
        )
        self.uploadedStore = UploadedItemStore()
    }

    // MARK: - 公开接口：单条上传

    /// 上传单个条目，返回可观察的 UploadTask。
    /// - throws: `UploadableItemError` 或 `StorageError`
    @discardableResult
    public func upload(item: any UploadableItem) async throws -> UploadTask {
        let filterResult = await filter(item: item)
        guard case .accepted = filterResult else {
            handleSkipped(reason: filterResult)
            throw UploadServiceError.itemFiltered(filterResult)
        }
        return try await enqueue(item: item)
    }

    // MARK: - 公开接口：批量上传

    /// 批量上传，跳过不符合条件的条目（不抛出），返回成功入队的任务列表。
    @discardableResult
    public func upload(items: [any UploadableItem]) async -> [UploadTask] {
        var tasks: [UploadTask] = []
        for item in items {
            let filterResult = await filter(item: item)
            guard case .accepted = filterResult else {
                handleSkipped(reason: filterResult)
                continue
            }
            do {
                let task = try await enqueue(item: item)
                tasks.append(task)
            } catch {
                statistics.totalFailed += 1
            }
        }
        return tasks
    }

    // MARK: - 公开接口：控制

    /// 取消所有进行中和等待中的任务
    public func cancelAll() async {
        await queue.cancelAll()
    }

    /// 重置统计数据
    public func resetStatistics() {
        statistics = UploadServiceStatistics()
    }

    /// 清除"已上传"记录，下次会重新上传所有条目
    public func clearUploadHistory() async {
        await uploadedStore.clearAll()
    }

    // MARK: - 内部：过滤

    private func filter(item: any UploadableItem) async -> ItemFilterResult {
        // 媒体类型
        guard configuration.allowedMediaTypes.contains(item.mediaType) else {
            return .skippedMediaType(item.mediaType)
        }

        // 文件大小（仅在有预期大小时检查）
        if let maxSize = configuration.maxFileSizeBytes,
           let fileSize = item.expectedFileSize,
           fileSize > maxSize {
            return .skippedFileSize(fileSize)
        }

        // 去重
        if configuration.skipAlreadyUploaded {
            let remotePath = configuration.pathStrategy.remotePath(
                for: item, baseFolder: configuration.baseFolder)
            if await uploadedStore.isUploaded(itemId: item.uploadItemId, remotePath: remotePath) {
                return .skippedAlreadyUploaded(remotePath: remotePath)
            }
        }

        return .accepted
    }

    // MARK: - 内部：入队

    private func enqueue(item: any UploadableItem) async throws -> UploadTask {
        // 解析本地 URL（可能触发导出/下载）
        let localURL = try await item.resolveLocalURL()

        let remotePath = configuration.pathStrategy.remotePath(
            for: item, baseFolder: configuration.baseFolder)

        let request = UploadRequest(
            localURL: localURL,
            remotePath: remotePath,
            contentType: item.mediaType.contentType,
            metadata: item.uploadMetadata,
            overwritePolicy: .skip
        )

        let task = await queue.enqueue(request)

        // 异步监听任务结果，更新统计和已上传记录
        Task { [weak self, localURL, configuration] in
            guard let self else { return }
            for await state in task.stateStream() {
                switch state {
                case .completed(let result):
                    await self.handleCompleted(
                        item: item,
                        result: result,
                        tempURL: configuration.cleanupTempFiles ? localURL : nil
                    )
                case .failed:
                    await self.handleFailed()
                default:
                    break
                }
            }
        }

        return task
    }

    // MARK: - 内部：结果处理

    private func handleCompleted(
        item: any UploadableItem,
        result: UploadResult,
        tempURL: URL?
    ) async {
        // 更新统计
        statistics.totalUploaded += 1
        statistics.totalBytesUploaded += result.remoteInfo.size
        statistics.lastUploadDate = .now
        let total = Double(statistics.totalUploaded)
        statistics.averageSpeedBytesPerSec =
            (statistics.averageSpeedBytesPerSec * (total - 1) + result.averageSpeed) / total

        // 记录已上传
        await uploadedStore.markUploaded(
            itemId: item.uploadItemId,
            remotePath: result.remoteInfo.path
        )

        // 清理临时文件
        if let url = tempURL {
            // 只清理 UploadService 自己导出到 temp 目录的文件，不碰用户原始文件
            let tempRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("UploadService").path
            if url.path.hasPrefix(tempRoot) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func handleFailed() {
        statistics.totalFailed += 1
    }

    private func handleSkipped(reason: ItemFilterResult) {
        statistics.totalSkipped += 1
    }
}

// MARK: - 服务错误

public enum UploadServiceError: Error, Sendable {
    case itemFiltered(ItemFilterResult)
}

// MARK: - 已上传记录存储（防重复上传）

/// 简单的 actor 包装，将已上传记录持久化到 UserDefaults。
/// 生产环境可替换为 SQLite 或 Core Data。
private actor UploadedItemStore {
    private var records: [String: String] = [:]   // itemId -> remotePath
    private let defaultsKey = "com.uploadservice.uploaded_items"

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            records = decoded
        }
    }

    func isUploaded(itemId: String, remotePath: String) -> Bool {
        records[itemId] == remotePath
    }

    func markUploaded(itemId: String, remotePath: String) {
        records[itemId] = remotePath
        persist()
    }

    func clearAll() {
        records.removeAll()
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
