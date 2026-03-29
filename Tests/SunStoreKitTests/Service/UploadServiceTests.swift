// Tests/SunStoreKitTests/UploadServiceTests.swift
// Swift 6.3 | SunStoreKit 测试（Swift Testing）

import Testing
import Foundation
@testable import SunStoreKit

// MARK: - Mock Provider

final class MockStorageProvider: StorageProvider, @unchecked Sendable {
    let id: String
    let displayName: String

    var shouldFailUpload = false
    var uploadDelay: TimeInterval = 0
    var existingPaths: Set<String> = []
    var uploadError: StorageError = .uploadFailed(reason: "mock error", underlying: nil)

    private(set) var uploadedRequests: [UploadRequest] = []
    private(set) var uploadCallCount: Int = 0
    private let lock = NSLock()

    init(id: String = "mock", displayName: String = "Mock Provider") {
        self.id = id
        self.displayName = displayName
    }

    func testConnection() async throws {}

    func upload(
        _ request: UploadRequest,
        progress: (@Sendable (UploadProgress) -> Void)?
    ) async throws -> UploadResult {
        lock.withLock { uploadCallCount += 1 }

        if uploadDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(uploadDelay * 1_000_000_000))
        }
        if shouldFailUpload { throw uploadError }

        progress?(UploadProgress(bytesUploaded: 512,  totalBytes: 1024, speed: 1024))
        progress?(UploadProgress(bytesUploaded: 1024, totalBytes: 1024, speed: 1024))

        lock.withLock { uploadedRequests.append(request) }

        let fileSize: Int64 = 1024
        return UploadResult(
            request: request,
            remoteInfo: RemoteFileInfo(
                path: request.remotePath,
                name: (request.remotePath as NSString).lastPathComponent,
                size: fileSize,
                modifiedAt: .now,
                contentType: request.contentType
            ),
            duration: 0.1,
            averageSpeed: Double(fileSize) / 0.1
        )
    }

    func fileExists(at path: String) async throws -> Bool { existingPaths.contains(path) }
    func listDirectory(_ path: String) async throws -> [RemoteFileInfo] { [] }
    func createDirectory(_ path: String) async throws {}
    func delete(at path: String) async throws {}
}

// MARK: - Mock UploadableItem

struct MockUploadItem: UploadableItem {
    let uploadItemId: String
    let filename: String
    let mediaType: UploadMediaType
    let creationDate: Date
    let expectedFileSize: Int64?
    let uploadMetadata: [String: String]
    var localURL: URL?
    var resolveError: Error?

    init(
        id: String = UUID().uuidString,
        filename: String = "test.jpg",
        mediaType: UploadMediaType = .photo,
        creationDate: Date = Date(timeIntervalSince1970: 1_700_000_000),
        fileSize: Int64? = 1024,
        metadata: [String: String] = [:],
        localURL: URL? = nil,
        resolveError: Error? = nil
    ) {
        self.uploadItemId    = id
        self.filename        = filename
        self.mediaType       = mediaType
        self.creationDate    = creationDate
        self.expectedFileSize = fileSize
        self.uploadMetadata  = metadata
        self.localURL        = localURL
        self.resolveError    = resolveError
    }

    func resolveLocalURL() async throws -> URL {
        if let e = resolveError { throw e }
        if let u = localURL    { return u }
        return FileManager.default.temporaryDirectory.appendingPathComponent(filename)
    }
}

// MARK: - 辅助

func makeTempFile(name: String = "test.jpg", size: Int = 1024) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("SunStoreKitTests/\(name)")
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data(repeating: 0xFF, count: size).write(to: url)
    return url
}

/// 等待 UploadTask 进入终态（completed / failed / cancelled），返回最终状态。
func waitForTerminal(_ task: UploadTask) async -> UploadTaskState {
    for await state in task.stateStream() {
        switch state {
        case .completed, .failed, .cancelled: return state
        default: continue
        }
    }
    return .cancelled
}

// MARK: - UploadMediaType

@Suite("UploadMediaType")
struct UploadMediaTypeTests {

    @Test("photo → image/jpeg")
    func contentType_photo() {
        #expect(UploadMediaType.photo.contentType == "image/jpeg")
    }

    @Test("raw → image/x-raw")
    func contentType_raw() {
        #expect(UploadMediaType.raw.contentType == "image/x-raw")
    }

    @Test("video → video/quicktime")
    func contentType_video() {
        #expect(UploadMediaType.video.contentType == "video/quicktime")
    }

    @Test("livePhoto → image/heic")
    func contentType_livePhoto() {
        #expect(UploadMediaType.livePhoto.contentType == "image/heic")
    }

    @Test("unknown → application/octet-stream")
    func contentType_unknown() {
        #expect(UploadMediaType.unknown.contentType == "application/octet-stream")
    }

    @Test("allCases 共 7 个")
    func allCases_count() {
        #expect(UploadMediaType.allCases.count == 7)
    }

    @Test("contentType 覆盖所有 case", arguments: UploadMediaType.allCases)
    func contentType_notEmpty(type: UploadMediaType) {
        #expect(!type.contentType.isEmpty)
    }
}

// MARK: - LocalFileUploadItem

@Suite("LocalFileUploadItem")
struct LocalFileUploadItemTests {

    let tempURL = makeTempFile(name: "local_test.jpg")

    @Test("从已有文件初始化，属性正确")
    func init_fromExistingFile() {
        let item = LocalFileUploadItem(fileURL: tempURL, mediaType: .photo)
        #expect(item.filename == "local_test.jpg")
        #expect(item.mediaType == .photo)
        #expect(item.expectedFileSize == 1024)
    }

    @Test("自定义 id")
    func init_customId() {
        let item = LocalFileUploadItem(fileURL: tempURL, id: "custom-id-123")
        #expect(item.uploadItemId == "custom-id-123")
    }

    @Test("默认 id 为文件路径")
    func init_defaultId_isPath() {
        let item = LocalFileUploadItem(fileURL: tempURL)
        #expect(item.uploadItemId == tempURL.path)
    }

    @Test("resolveLocalURL 返回原始路径")
    func resolveLocalURL_existingFile() async throws {
        let item = LocalFileUploadItem(fileURL: tempURL)
        let resolved = try await item.resolveLocalURL()
        #expect(resolved == tempURL)
    }

    @Test("文件不存在时 resolveLocalURL 抛出 fileUnavailable")
    func resolveLocalURL_missingFile_throws() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent_\(UUID().uuidString).jpg")
        let item = LocalFileUploadItem(fileURL: missing)

        do {
            _ = try await item.resolveLocalURL()
            Issue.record("应抛出 fileUnavailable，但未抛出")
        } catch UploadableItemError.fileUnavailable(let id) {
            #expect(id == item.uploadItemId)
        } catch {
            Issue.record("错误类型不对：\(error)")
        }
    }

    @Test("默认元数据为空")
    func defaultMetadata_isEmpty() {
        let item = LocalFileUploadItem(fileURL: tempURL)
        #expect(item.uploadMetadata.isEmpty)
    }

    @Test("自定义元数据正确传入")
    func customMetadata() {
        let item = LocalFileUploadItem(fileURL: tempURL, metadata: ["x-device": "Canon R5"])
        #expect(item.uploadMetadata["x-device"] == "Canon R5")
    }
}

// MARK: - RemotePathStrategy

@Suite("RemotePathStrategy")
struct RemotePathStrategyTests {

    // 2023-11-15 固定时间
    let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    func makeItem(
        filename: String = "IMG_001.jpg",
        mediaType: UploadMediaType = .photo,
        date: Date? = nil
    ) -> MockUploadItem {
        MockUploadItem(filename: filename, mediaType: mediaType,
                       creationDate: date ?? fixedDate)
    }

    @Test("DateOrganized 路径结构：base/YYYY/MM/DD/filename")
    func dateOrganized_structure() {
        let path = DateOrganizedPathStrategy()
            .remotePath(for: makeItem(filename: "photo.jpg"), baseFolder: "/backup")
        #expect(path.hasPrefix("/backup/"))
        #expect(path.hasSuffix("/photo.jpg"))
        let parts = path.split(separator: "/").map(String.init)
        #expect(parts.count == 5)
        #expect(parts[2].count == 2)   // MM
        #expect(parts[3].count == 2)   // DD
    }

    @Test("DateOrganized 不同日期产生不同路径")
    func dateOrganized_differentDates() {
        let s = DateOrganizedPathStrategy()
        let p1 = s.remotePath(for: makeItem(date: Date(timeIntervalSince1970: 1_700_000_000)), baseFolder: "/b")
        let p2 = s.remotePath(for: makeItem(date: Date(timeIntervalSince1970: 1_710_000_000)), baseFolder: "/b")
        #expect(p1 != p2)
    }

    @Test("MediaType 路径", arguments: [
        (UploadMediaType.photo,      "photos"),
        (UploadMediaType.raw,        "photos"),
        (UploadMediaType.livePhoto,  "photos"),
        (UploadMediaType.video,      "videos"),
        (UploadMediaType.slowMotion, "videos"),
        (UploadMediaType.timelapse,  "videos"),
        (UploadMediaType.unknown,    "others"),
    ] as [(UploadMediaType, String)])
    func mediaType_subfolder(type: UploadMediaType, expected: String) {
        let path = MediaTypePathStrategy()
            .remotePath(for: makeItem(mediaType: type), baseFolder: "/b")
        #expect(path.contains("/\(expected)/"))
    }

    @Test("Flat 策略：直接拼接到 base")
    func flat_noSubfolder() {
        let path = FlatPathStrategy().remotePath(for: makeItem(filename: "x.jpg"), baseFolder: "/b")
        #expect(path == "/b/x.jpg")
    }

    @Test("Custom 闭包策略")
    func custom_closure() {
        let strategy = CustomPathStrategy { item, base in "\(base)/custom/\(item.filename)" }
        let path = strategy.remotePath(for: makeItem(filename: "y.jpg"), baseFolder: "/base")
        #expect(path == "/base/custom/y.jpg")
    }

    @Test("路径中不含双斜杠")
    func noDoubleSlash() {
        let path = FlatPathStrategy().remotePath(for: makeItem(filename: "a.jpg"), baseFolder: "/backup")
        #expect(!path.contains("//"))
    }
}

// MARK: - UploadService

@Suite("UploadService")
struct UploadServiceTests {

    // 每个 @Test 方法独立构造，避免共享状态
    func makeService(
        allowedTypes: Set<UploadMediaType> = Set(UploadMediaType.allCases),
        maxFileSize: Int64? = nil,
        skipDuplicates: Bool = false,
        pathStrategy: any RemotePathStrategy = FlatPathStrategy()
    ) -> (UploadService, MockStorageProvider) {
        let provider = MockStorageProvider()
        let service = UploadService(
            provider: provider,
            configuration: UploadServiceConfiguration(
                baseFolder: "/test",
                pathStrategy: pathStrategy,
                // retryCount: 0 避免失败测试因重试等待数秒
                queueConfig: UploadQueue.Configuration(
                    maxConcurrentUploads: 3,
                    retryCount: 0,
                    retryDelay: 0
                ),
                allowedMediaTypes: allowedTypes,
                maxFileSizeBytes: maxFileSize,
                skipAlreadyUploaded: skipDuplicates,
                cleanupTempFiles: false
            )
        )
        return (service, provider)
    }

    // MARK: 基础上传

    @Test("单条上传成功，任务进入 completed")
    func upload_singleItem_success() async throws {
        let (service, provider) = makeService()
        let tempFile = makeTempFile()
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let task = try await service.upload(item: MockUploadItem(localURL: tempFile))
        let state = await waitForTerminal(task)

        guard case .completed = state else {
            Issue.record("期望 completed，实际：\(state)")
            return
        }
        #expect(provider.uploadCallCount == 1)
    }

    @Test("批量上传 5 个，全部入队")
    func upload_batchItems_allEnqueued() async throws {
        let (service, _) = makeService()
        let tempFile = makeTempFile()
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let items = (0..<5).map { i in
            MockUploadItem(id: "item-\(i)", filename: "photo_\(i).jpg", localURL: tempFile)
        }
        let tasks = await service.upload(items: items)
        #expect(tasks.count == 5)
    }

    @Test("上传后远端路径包含文件名")
    func upload_remotePath_containsFilename() async throws {
        let (service, provider) = makeService()
        let tempFile = makeTempFile(name: "portrait.jpg")
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let task = try await service.upload(
            item: MockUploadItem(filename: "portrait.jpg", localURL: tempFile))
        _ = await waitForTerminal(task)

        #expect(provider.uploadedRequests.first?.remotePath.hasSuffix("portrait.jpg") == true)
    }

    // MARK: 过滤：媒体类型

    @Test("不允许的媒体类型抛出 itemFiltered")
    func upload_filteredByMediaType_throws() async throws {
        let (service, _) = makeService(allowedTypes: [.photo])
        let tempFile = makeTempFile()
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let videoItem = MockUploadItem(mediaType: .video, localURL: tempFile)
        await #expect(throws: UploadServiceError.self) {
            _ = try await service.upload(item: videoItem)
        }
    }

    @Test("批量上传混合类型，只有允许的入队")
    func upload_batchMixedTypes_onlyAllowedEnqueued() async {
        let (service, _) = makeService(allowedTypes: [.photo, .raw])
        let tempFile = makeTempFile()
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let items: [any UploadableItem] = [
            MockUploadItem(id: "p1", mediaType: .photo, localURL: tempFile),
            MockUploadItem(id: "v1", mediaType: .video, localURL: tempFile),
            MockUploadItem(id: "r1", mediaType: .raw,   localURL: tempFile),
            MockUploadItem(id: "v2", mediaType: .video, localURL: tempFile),
        ]
        let tasks = await service.upload(items: items)
        #expect(tasks.count == 2)
    }

    // MARK: 过滤：文件大小

    @Test("超过大小限制抛出 itemFiltered")
    func upload_filteredByFileSize_throws() async throws {
        let (service, _) = makeService(maxFileSize: 512)
        let tempFile = makeTempFile()
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let bigItem = MockUploadItem(fileSize: 2048, localURL: tempFile)
        await #expect(throws: UploadServiceError.self) {
            _ = try await service.upload(item: bigItem)
        }
    }

    @Test("expectedFileSize 为 nil 时不受大小限制")
    func upload_noExpectedSize_notFiltered() async throws {
        let (service, _) = makeService(maxFileSize: 10)
        let tempFile = makeTempFile()
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let item = MockUploadItem(fileSize: nil, localURL: tempFile)
        let task = try await service.upload(item: item)
        #expect(task.id != UUID())  // 成功入队即可
    }

    // MARK: 过滤：去重

    @Test("相同 item 二次上传被跳过，清除历史后可再次上传")
    func upload_deduplication() async throws {
        let (service, _) = makeService(skipDuplicates: true)
        let tempFile = makeTempFile()
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let item = MockUploadItem(id: "dedup-\(UUID().uuidString)", filename: "dup.jpg", localURL: tempFile)

        // 第一次上传
        let task1 = try await service.upload(item: item)
        _ = await waitForTerminal(task1)
        try await Task.sleep(nanoseconds: 200_000_000)  // 等待 actor 内记录写入

        // 第二次应被跳过
        do {
            _ = try await service.upload(item: item)
            Issue.record("第二次上传应被过滤")
        } catch UploadServiceError.itemFiltered(let reason) {
            guard case .skippedAlreadyUploaded = reason else {
                Issue.record("过滤原因不对：\(reason)")
                return
            }
        }

        // 清除历史后可重新上传
        await service.clearUploadHistory()
        try await Task.sleep(nanoseconds: 100_000_000)
        let task3 = try await service.upload(item: item)
        let finalState = await waitForTerminal(task3)
        guard case .completed = finalState else {
            Issue.record("清除历史后重新上传应成功，实际：\(finalState)")
            return
        }
    }

    // MARK: 失败处理

    @Test("Provider 抛出时任务进入 failed 状态")
    func upload_providerFails_taskStateFailed() async throws {
        let (service, provider) = makeService()
        let tempFile = makeTempFile()
        defer { try? FileManager.default.removeItem(at: tempFile) }

        provider.shouldFailUpload = true
        let task = try await service.upload(item: MockUploadItem(localURL: tempFile))
        let state = await waitForTerminal(task)

        guard case .failed = state else {
            Issue.record("期望 failed，实际：\(state)")
            return
        }
    }

    @Test("resolveLocalURL 抛出时 upload 同步抛出")
    func upload_resolveURLFails_throws() async {
        let (service, _) = makeService()
        let item = MockUploadItem(
            resolveError: UploadableItemError.fileUnavailable(id: "bad-item"))

        await #expect(throws: UploadableItemError.self) {
            _ = try await service.upload(item: item)
        }
    }

    // MARK: 统计

    @Test("上传成功后统计更新")
    func statistics_updatedOnSuccess() async throws {
        let (service, _) = makeService()
        let tempFile = makeTempFile()
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let task = try await service.upload(item: MockUploadItem(localURL: tempFile))
        _ = await waitForTerminal(task)
        try await Task.sleep(nanoseconds: 100_000_000)

        let stats = await service.statistics
        #expect(stats.totalUploaded == 1)
        #expect(stats.totalFailed == 0)
        #expect(stats.totalBytesUploaded > 0)
        #expect(stats.lastUploadDate != nil)
    }

    @Test("上传失败后统计更新")
    func statistics_updatedOnFailure() async throws {
        let (service, provider) = makeService()
        let tempFile = makeTempFile()
        defer { try? FileManager.default.removeItem(at: tempFile) }

        provider.shouldFailUpload = true
        let task = try await service.upload(item: MockUploadItem(localURL: tempFile))
        _ = await waitForTerminal(task)
        try await Task.sleep(nanoseconds: 100_000_000)

        let stats = await service.statistics
        #expect(stats.totalFailed == 1)
    }

    @Test("被过滤的条目计入 totalSkipped")
    func statistics_updatedOnSkip() async {
        let (service, _) = makeService(allowedTypes: [.photo])
        let tempFile = makeTempFile()
        defer { try? FileManager.default.removeItem(at: tempFile) }

        _ = await service.upload(items: [
            MockUploadItem(id: "s1", mediaType: .photo, localURL: tempFile),
            MockUploadItem(id: "s2", mediaType: .video, localURL: tempFile),
        ])
        try? await Task.sleep(nanoseconds: 100_000_000)

        let stats = await service.statistics
        #expect(stats.totalSkipped == 1)
    }

    @Test("totalProcessed = uploaded + failed + skipped")
    func statistics_totalProcessed_isSum() async {
        let (service, _) = makeService()
        let stats = await service.statistics
        #expect(stats.totalProcessed == stats.totalUploaded + stats.totalFailed + stats.totalSkipped)
    }

    @Test("resetStatistics 清零所有统计")
    func statistics_reset() async throws {
        let (service, _) = makeService()
        let tempFile = makeTempFile()
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let task = try await service.upload(item: MockUploadItem(localURL: tempFile))
        _ = await waitForTerminal(task)
        try await Task.sleep(nanoseconds: 100_000_000)

        await service.resetStatistics()
        let stats = await service.statistics
        #expect(stats.totalUploaded == 0)
        #expect(stats.lastUploadDate == nil)
    }

    // MARK: 并发

    @Test("10 个并发任务全部完成")
    func upload_concurrentBatch_allComplete() async throws {
        let (service, provider) = makeService()
        let tempFile = makeTempFile()
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let count = 10
        let items = (0..<count).map { i in
            MockUploadItem(id: "c-\(i)", filename: "c_\(i).jpg", localURL: tempFile)
        }
        let tasks = await service.upload(items: items)
        #expect(tasks.count == count)

        await withTaskGroup(of: Void.self) { group in
            for task in tasks {
                group.addTask { _ = await waitForTerminal(task) }
            }
        }
        #expect(provider.uploadCallCount == count)
    }
}

// MARK: - UploadQueue

@Suite("UploadQueue")
struct UploadQueueTests {

    func makeRequest(name: String = "file.jpg") -> UploadRequest {
        UploadRequest(
            localURL: FileManager.default.temporaryDirectory.appendingPathComponent(name),
            remotePath: "/remote/\(name)",
            contentType: "image/jpeg"
        )
    }

    @Test("enqueue 返回任务，remotePath 正确")
    func enqueue_returnsTask() async {
        let provider = MockStorageProvider()
        let queue = UploadQueue(provider: provider)
        let task = await queue.enqueue(makeRequest())
        #expect(task.request.remotePath == "/remote/file.jpg")
    }

    @Test("cancelAll 后 provider 调用次数极少")
    func cancelAll_stopsExecution() async throws {
        let provider = MockStorageProvider()
        provider.uploadDelay = 5.0
        let queue = UploadQueue(provider: provider, configuration: .init(maxConcurrentUploads: 1))

        let tempFile = makeTempFile(name: "cancel_test.jpg")
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let request = UploadRequest(
            localURL: tempFile, remotePath: "/r/cancel.jpg", contentType: "image/jpeg")
        let tasks = await queue.enqueueAll([request, request, request])
        #expect(tasks.count == 3)

        await queue.cancelAll()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(provider.uploadCallCount <= 1)
    }
}

// MARK: - MockStorageProvider 行为验证

@Suite("MockStorageProvider")
struct MockStorageProviderTests {

    @Test("upload 记录请求")
    func upload_recordsRequest() async throws {
        let provider = MockStorageProvider()
        let tempFile = makeTempFile()
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let request = UploadRequest(
            localURL: tempFile, remotePath: "/r/recorded.jpg", contentType: "image/jpeg")
        _ = try await provider.upload(request, progress: nil)

        #expect(provider.uploadedRequests.count == 1)
        #expect(provider.uploadedRequests.first?.remotePath == "/r/recorded.jpg")
    }

    @Test("shouldFailUpload = true 时抛出 StorageError")
    func upload_whenShouldFail_throws() async {
        let provider = MockStorageProvider()
        provider.shouldFailUpload = true
        let tempFile = makeTempFile()
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let request = UploadRequest(
            localURL: tempFile, remotePath: "/r/fail.jpg", contentType: "image/jpeg")
        await #expect(throws: StorageError.self) {
            _ = try await provider.upload(request, progress: nil)
        }
    }

    @Test("fileExists 匹配预配置路径")
    func fileExists_matchesConfiguredPaths() async throws {
        let provider = MockStorageProvider()
        provider.existingPaths = ["/exists/file.jpg"]
        #expect(try await provider.fileExists(at: "/exists/file.jpg") == true)
        #expect(try await provider.fileExists(at: "/not/here.jpg") == false)
    }

    @Test("upload 上报进度，最终 fractionCompleted == 1.0")
    func upload_reportsProgress() async throws {
        let provider = MockStorageProvider()
        let tempFile = makeTempFile()
        defer { try? FileManager.default.removeItem(at: tempFile) }

        // MockStorageProvider.upload 是串行的，progress 回调在 upload 返回前同步触发
        // 用 nonisolated(unsafe) 标记，告知编译器这里不存在真正的并发写入
        nonisolated(unsafe) var reports: [UploadProgress] = []
        let request = UploadRequest(
            localURL: tempFile, remotePath: "/r/progress.jpg", contentType: "image/jpeg")
        _ = try await provider.upload(request) { p in
            reports.append(p)
        }

        #expect(!reports.isEmpty)
        #expect(reports.last?.fractionCompleted == 1.0)
    }
}
