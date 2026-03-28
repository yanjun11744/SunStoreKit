// Sources/CameraUploader/Core/UploadTask.swift
// Swift 6.3 | 上传任务与队列管理（Layer 2）

import Foundation

// MARK: - 上传任务状态

public enum UploadTaskState: Sendable, Equatable {
    case pending
    case running(progress: Double)
    case paused
    case completed(UploadResult)
    case failed(StorageError)
    case cancelled
}

// MARK: - 上传任务

public final class UploadTask: @unchecked Sendable, Identifiable {
    public let id: UUID
    public let request: UploadRequest
    public let providerId: String
    public private(set) var state: UploadTaskState = .pending
    public private(set) var createdAt: Date = .now

    private let stateLock = NSLock()
    private var continuations: [AsyncStream<UploadTaskState>.Continuation] = []
    var cancellationTask: Task<Void, Never>?

    public init(request: UploadRequest, providerId: String) {
        self.id = UUID()
        self.request = request
        self.providerId = providerId
    }

    /// 订阅状态变化流
    public func stateStream() -> AsyncStream<UploadTaskState> {
        AsyncStream { continuation in
            stateLock.lock()
            continuations.append(continuation)
            continuation.yield(state)
            stateLock.unlock()
        }
    }

    func updateState(_ newState: UploadTaskState) {
        stateLock.lock()
        state = newState
        let conts = continuations
        stateLock.unlock()
        for cont in conts {
            cont.yield(newState)
            if case .completed = newState { cont.finish() }
            if case .failed = newState    { cont.finish() }
            if case .cancelled = newState { cont.finish() }
        }
    }

    public func cancel() {
        cancellationTask?.cancel()
        updateState(.cancelled)
    }
}

// MARK: - 并发上传队列（Layer 2）

public actor UploadQueue {
    public struct Configuration: Sendable {
        public var maxConcurrentUploads: Int
        public var retryCount: Int
        public var retryDelay: TimeInterval
        public var chunkSize: Int             // bytes，用于分片上传

        public init(
            maxConcurrentUploads: Int = 3,
            retryCount: Int = 3,
            retryDelay: TimeInterval = 2.0,
            chunkSize: Int = 8 * 1024 * 1024  // 8 MB
        ) {
            self.maxConcurrentUploads = maxConcurrentUploads
            self.retryCount = retryCount
            self.retryDelay = retryDelay
            self.chunkSize = chunkSize
        }
    }

    private let configuration: Configuration
    private let provider: any StorageProvider
    private var pendingTasks: [UploadTask] = []
    private var activeTasks: [UUID: Task<Void, Never>] = [:]

    public init(provider: any StorageProvider, configuration: Configuration = .init()) {
        self.provider = provider
        self.configuration = configuration
    }

    /// 加入队列并返回任务
    @discardableResult
    public func enqueue(_ request: UploadRequest) -> UploadTask {
        let task = UploadTask(request: request, providerId: provider.id)
        pendingTasks.append(task)
        Task { await self.drainQueue() }
        return task
    }

    /// 批量加入
    public func enqueueAll(_ requests: [UploadRequest]) -> [UploadTask] {
        requests.map { enqueue($0) }
    }

    /// 取消所有任务
    public func cancelAll() {
        pendingTasks.forEach { $0.cancel() }
        pendingTasks.removeAll()
        activeTasks.values.forEach { $0.cancel() }
        activeTasks.removeAll()
    }

    // MARK: - 内部调度

    private func drainQueue() async {
        while activeTasks.count < configuration.maxConcurrentUploads,
              !pendingTasks.isEmpty {
            let task = pendingTasks.removeFirst()
            let workTask = Task { [weak self] in
                guard let self else { return }
                await self.execute(task)
            }
            activeTasks[task.id] = workTask
        }
    }

    private func execute(_ uploadTask: UploadTask) async {
        defer {
            activeTasks.removeValue(forKey: uploadTask.id)
            Task { await drainQueue() }
        }

        let request = uploadTask.request
        var lastError: StorageError = .cancelled

        for attempt in 0...configuration.retryCount {
            guard !Task.isCancelled else {
                uploadTask.updateState(.cancelled)
                return
            }

            if attempt > 0 {
                try? await Task.sleep(nanoseconds: UInt64(configuration.retryDelay * 1_000_000_000))
            }

            do {
                uploadTask.updateState(.running(progress: 0))

                let result = try await provider.upload(request) { progress in
                    uploadTask.updateState(.running(progress: progress.fractionCompleted))
                }
                uploadTask.updateState(.completed(result))
                return
            } catch let error as StorageError {
                lastError = error
                // 不可重试的错误直接失败
                if case .authenticationFailed = error { break }
                if case .permissionDenied = error { break }
                if case .cancelled = error { break }
            } catch {
                lastError = .unknown(error)
            }
        }

        uploadTask.updateState(.failed(lastError))
    }
}

extension UploadResult: Equatable {
    public static func == (lhs: UploadResult, rhs: UploadResult) -> Bool {
        lhs.remoteInfo.path == rhs.remoteInfo.path && lhs.duration == rhs.duration
    }
}
