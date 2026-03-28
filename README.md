# SunStoreKit

Swift 6.3 · async/await · actor-safe

通用网络存储上传库。不绑定任何具体文件来源——无论是磁盘文件、相册 PHAsset、还是通过 USB 连接的 ICCameraFile，只要实现一个协议就能上传到群晖、飞牛、WebDAV 等任何后端。

---

## 功能概览

- **`UploadableItem` 协议**：统一抽象，解耦文件来源与上传逻辑
- **`UploadService`**：actor 安全的顶层编排器，支持单条/批量上传、过滤、去重、统计
- **内置适配器**：`LocalFileUploadItem`（磁盘文件）、`PHAssetUploadItem`（相册，条件编译）
- **路径策略**：按日期归档 / 按媒体类型分组 / 平铺 / 自定义闭包，可自由扩展
- **多后端支持**：群晖 DSM、飞牛 fnOS、WebDAV（坚果云、Nextcloud、Seafile 等）
- **并发队列**：可配置并发数、自动重试、任务状态流（AsyncStream）
- **去重**：基于 `uploadItemId` 持久化记录，跳过已上传条目

---

## 安装

### Swift Package Manager

在 `Package.swift` 中添加依赖：

```swift
dependencies: [
    .package(url: "https://github.com/yourname/SunStoreKit.git", from: "1.0.0")
],
targets: [
    .target(name: "YourApp", dependencies: ["SunStoreKit"])
]
```

或在 Xcode → File → Add Package Dependencies 中直接输入仓库地址。

---

## 快速开始

### 1. 配置存储后端

```swift
import SunStoreKit

// 群晖
let provider = StorageProviderRegistry.shared.registerSynology(
    configuration: SynologyConfiguration(
        host: "192.168.1.100",
        username: "admin",
        password: "yourpassword",
        destinationFolder: "/photo/camera"
    )
)

// 或飞牛
let provider = StorageProviderRegistry.shared.registerFeiNiu(
    configuration: FeiNiuConfiguration(
        host: "192.168.1.200",
        username: "admin",
        password: "yourpassword"
    )
)

// 或 WebDAV（坚果云）
let provider = StorageProviderRegistry.shared.registerWebDAV(
    id: "jianguoyun",
    displayName: "坚果云",
    configuration: WebDAVPreset.jianguoyun(
        username: "user@example.com",
        appPassword: "app-password"
    )
)
```

### 2. 创建 UploadService

```swift
let service = UploadService(
    provider: provider,
    configuration: UploadServiceConfiguration(
        baseFolder: "/camera_backup",
        pathStrategy: DateOrganizedPathStrategy(),  // 按日期归档
        skipAlreadyUploaded: true
    )
)
```

### 3. 上传文件

```swift
// 磁盘文件
let item = LocalFileUploadItem(
    fileURL: URL(fileURLWithPath: "/tmp/photo.jpg"),
    mediaType: .photo
)
let task = try await service.upload(item: item)

// 观察进度
for await state in task.stateStream() {
    switch state {
    case .running(let progress):
        print("上传中：\(Int(progress * 100))%")
    case .completed(let result):
        print("完成：\(result.remoteInfo.path)，速度 \(result.averageSpeed / 1024) KB/s")
    case .failed(let error):
        print("失败：\(error)")
    default:
        break
    }
}

// 批量上传（不符合条件的自动跳过，不抛出）
let tasks = await service.upload(items: photoItems)
print("入队 \(tasks.count) 个任务")
```

---

## UploadableItem 协议

任何文件类型只需实现此协议即可接入上传服务：

```swift
public protocol UploadableItem: Sendable {
    var uploadItemId: String { get }        // 唯一标识（用于去重）
    var filename: String { get }            // 目标文件名（含扩展名）
    var mediaType: UploadMediaType { get }  // 媒体类型
    var creationDate: Date { get }          // 创建时间（用于路径策略）
    var expectedFileSize: Int64? { get }    // 预期大小，可选
    var uploadMetadata: [String: String] { get }  // 附加元数据，可选
    func resolveLocalURL() async throws -> URL    // 解析本地文件路径
}
```

`expectedFileSize` 和 `uploadMetadata` 有默认实现，最少只需实现 5 个属性和 1 个方法。

### 自定义适配（以 ICCameraFile 为例）

```swift
// App 侧扩展，不修改库本身
extension PhotoItem: UploadableItem {
    public var uploadItemId: String {
        "\(file.device?.UUIDString ?? "unknown")/\(file.name ?? "")"
    }
    public var filename: String { name }
    public var mediaType: UploadMediaType {
        if isRAW   { return .raw }
        if isVideo { return .video }
        if isHEIC  { return .livePhoto }
        return .photo
    }
    public var creationDate: Date { file.fileCreationDate ?? .now }

    public func resolveLocalURL() async throws -> URL {
        // 委托给你的 ICDownloadCoordinator
        try await ICDownloadCoordinator.shared.download(file: file, itemId: uploadItemId)
    }
}
```

---

## 路径策略

| 策略 | 结果示例 |
|------|----------|
| `DateOrganizedPathStrategy`（默认）| `/base/2024/06/20/IMG_001.jpg` |
| `MediaTypePathStrategy` | `/base/photos/IMG_001.jpg` |
| `FlatPathStrategy` | `/base/IMG_001.jpg` |
| `CustomPathStrategy` | 自定义闭包，完全自由 |

```swift
// 自定义：按品牌/年份归档
let strategy = CustomPathStrategy { item, base in
    let year = Calendar.current.component(.year, from: item.creationDate)
    let brand = (item.uploadMetadata["x-camera-brand"] ?? "unknown").lowercased()
    return "\(base)/\(brand)/\(year)/\(item.filename)"
}
```

---

## UploadServiceConfiguration 参数说明

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `baseFolder` | `"/uploads"` | 远端根目录 |
| `pathStrategy` | `DateOrganizedPathStrategy` | 路径策略 |
| `queueConfig.maxConcurrentUploads` | `3` | 最大并发数 |
| `queueConfig.retryCount` | `3` | 失败重试次数 |
| `queueConfig.retryDelay` | `2.0s` | 重试间隔 |
| `allowedMediaTypes` | 全部 | 允许上传的媒体类型 |
| `maxFileSizeBytes` | `nil`（不限） | 单文件大小上限 |
| `skipAlreadyUploaded` | `true` | 跳过已上传条目 |
| `cleanupTempFiles` | `true` | 上传后清理临时导出文件 |

---

## 统计信息

```swift
let stats = await service.statistics
print("已上传：\(stats.totalUploaded)")
print("失败：\(stats.totalFailed)")
print("跳过：\(stats.totalSkipped)")
print("总字节：\(stats.totalBytesUploaded / 1024 / 1024) MB")
print("平均速度：\(stats.averageSpeedBytesPerSec / 1024) KB/s")
```

---

## 支持的后端

| 后端 | 类 | 协议 |
|------|----|------|
| 群晖 DSM | `SynologyProvider` | 群晖 FileStation API |
| 飞牛 fnOS | `FeiNiuProvider` | WebDAV |
| 坚果云 | `WebDAVProvider` | WebDAV |
| Nextcloud | `WebDAVProvider` | WebDAV |
| Seafile | `WebDAVProvider` | WebDAV |
| ownCloud | `WebDAVProvider` | WebDAV |
| Box | `WebDAVProvider` | WebDAV |

实现 `StorageProvider` 协议即可接入任意后端（S3、SMB 等）。

---

## 要求

- Swift 6.3+
- macOS 13+ / iOS 16+
- Xcode 16+
