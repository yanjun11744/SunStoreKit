//
//  RemotePathStrategy.swift
//  Swift 6.3 | 远端路径策略（与具体文件类型解耦）
//
//  Created by Yanjun Sun on 2026/3/28.
//

import Foundation

// MARK: - 路径策略协议

/// 决定一个 UploadableItem 上传到远端的哪个路径。
/// 输入：条目元数据 + 根目录；输出：完整远端路径（含文件名）。
public protocol RemotePathStrategy: Sendable {
    func remotePath(for item: any UploadableItem, baseFolder: String) -> String
}

// MARK: - 按日期分组：/base/2024/06/20/filename.jpg

public struct DateOrganizedPathStrategy: RemotePathStrategy, Sendable {
    private let calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    public func remotePath(for item: any UploadableItem, baseFolder: String) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: item.creationDate)
        let y = c.year  ?? 2024
        let m = String(format: "%02d", c.month ?? 1)
        let d = String(format: "%02d", c.day   ?? 1)
        return "\(baseFolder)/\(y)/\(m)/\(d)/\(item.filename)"
    }
}

// MARK: - 按媒体类型分组：/base/photos/filename.jpg

public struct MediaTypePathStrategy: RemotePathStrategy, Sendable {
    public init() {}

    public func remotePath(for item: any UploadableItem, baseFolder: String) -> String {
        let sub: String
        switch item.mediaType {
        case .photo, .raw, .livePhoto:          sub = "photos"
        case .video, .slowMotion, .timelapse:   sub = "videos"
        case .unknown:                           sub = "others"
        }
        return "\(baseFolder)/\(sub)/\(item.filename)"
    }
}

// MARK: - 平铺：/base/filename.jpg

public struct FlatPathStrategy: RemotePathStrategy, Sendable {
    public init() {}

    public func remotePath(for item: any UploadableItem, baseFolder: String) -> String {
        "\(baseFolder)/\(item.filename)"
    }
}

// MARK: - 自定义闭包策略（方便快速使用）

public struct CustomPathStrategy: RemotePathStrategy, Sendable {
    private let resolver: @Sendable (any UploadableItem, String) -> String

    public init(_ resolver: @escaping @Sendable (any UploadableItem, String) -> String) {
        self.resolver = resolver
    }

    public func remotePath(for item: any UploadableItem, baseFolder: String) -> String {
        resolver(item, baseFolder)
    }
}
