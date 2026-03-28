// Sources/CameraUploader/Providers/WebDAVProvider.swift
// Swift 6.3 | WebDAV 存储提供者

import Foundation

// MARK: - WebDAV 配置

public struct WebDAVConfiguration: Sendable {
    public var baseURL: URL
    public var username: String
    public var password: String
    public var allowInsecureConnection: Bool
    public var timeoutInterval: TimeInterval
    public var customHeaders: [String: String]

    public init(
        baseURL: URL,
        username: String,
        password: String,
        allowInsecureConnection: Bool = false,
        timeoutInterval: TimeInterval = 60,
        customHeaders: [String: String] = [:]
    ) {
        self.baseURL = baseURL
        self.username = username
        self.password = password
        self.allowInsecureConnection = allowInsecureConnection
        self.timeoutInterval = timeoutInterval
        self.customHeaders = customHeaders
    }
}

// MARK: - WebDAV Provider

public final class WebDAVProvider: BaseHTTPProvider, StorageProvider, @unchecked Sendable {
    public let id: String
    public let displayName: String
    private let webdavConfig: WebDAVConfiguration

    public init(
        id: String = "webdav",
        displayName: String = "WebDAV",
        configuration: WebDAVConfiguration
    ) {
        self.id = id
        self.displayName = displayName
        self.webdavConfig = configuration

        let httpConfig = HTTPProviderConfiguration(
            baseURL: configuration.baseURL,
            authentication: .basic(username: configuration.username,
                                   password: configuration.password),
            timeoutInterval: configuration.timeoutInterval,
            allowInsecureConnection: configuration.allowInsecureConnection,
            additionalHeaders: configuration.customHeaders
        )
        super.init(configuration: httpConfig)
    }

    // MARK: - StorageProvider 实现

    public func testConnection() async throws {
        let url = configuration.baseURL
        var request = makeRequest(url: url, method: "PROPFIND")
        request.setValue("0", forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")

        let (_, response) = try await session.data(for: request)
        if let error = parseHTTPError(response, body: nil) { throw error }
    }

    public func upload(
        _ uploadRequest: UploadRequest,
        progress: (@Sendable (UploadProgress) -> Void)?
    ) async throws -> UploadResult {
        let startTime = Date()

        // 确保父目录存在
        let parent = (uploadRequest.remotePath as NSString).deletingLastPathComponent
        if !parent.isEmpty && parent != "/" {
            try await createDirectory(parent)
        }

        // 处理覆写策略
        try await handleOverwritePolicy(uploadRequest)

        // 构建目标 URL
        guard let targetURL = URL(string: configuration.baseURL.absoluteString + uploadRequest.remotePath) else {
            throw StorageError.invalidConfiguration("Invalid remote path: \(uploadRequest.remotePath)")
        }

        // 获取文件大小
        let attributes = try FileManager.default.attributesOfItem(atPath: uploadRequest.localURL.path)
        let fileSize = (attributes[.size] as? Int64) ?? 0

        // PUT 请求
        var request = makeRequest(url: targetURL, method: "PUT")
        request.setValue(uploadRequest.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(String(fileSize), forHTTPHeaderField: "Content-Length")

        let (_, response) = try await uploadWithProgress(
            request: request,
            fileURL: uploadRequest.localURL,
            totalBytes: fileSize,
            progress: progress
        )

        if let error = parseHTTPError(response, body: nil) { throw error }

        let duration = Date().timeIntervalSince(startTime)
        let remoteInfo = RemoteFileInfo(
            path: uploadRequest.remotePath,
            name: (uploadRequest.remotePath as NSString).lastPathComponent,
            size: fileSize,
            modifiedAt: .now,
            contentType: uploadRequest.contentType
        )
        return UploadResult(
            request: uploadRequest,
            remoteInfo: remoteInfo,
            duration: duration,
            averageSpeed: duration > 0 ? Double(fileSize) / duration : 0
        )
    }

    public func fileExists(at path: String) async throws -> Bool {
        guard let url = URL(string: configuration.baseURL.absoluteString + path) else {
            return false
        }
        var request = makeRequest(url: url, method: "PROPFIND")
        request.setValue("0", forHTTPHeaderField: "Depth")

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { return false }
        return httpResponse.statusCode == 207 || httpResponse.statusCode == 200
    }

    public func listDirectory(_ path: String) async throws -> [RemoteFileInfo] {
        guard let url = URL(string: configuration.baseURL.absoluteString + path) else {
            throw StorageError.invalidConfiguration("Invalid path: \(path)")
        }

        var request = makeRequest(url: url, method: "PROPFIND")
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")

        let propfindBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <propfind xmlns="DAV:">
          <prop>
            <getcontentlength/><getlastmodified/>
            <getcontenttype/><getetag/>
            <resourcetype/>
          </prop>
        </propfind>
        """
        request.httpBody = propfindBody.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        if let error = parseHTTPError(response, body: data) { throw error }

        return parseMultiStatusResponse(data: data, basePath: path)
    }

    public func createDirectory(_ path: String) async throws {
        // WebDAV MKCOL 只能逐级创建，需要递归
        let components = path.split(separator: "/").map(String.init)
        var currentPath = ""
        for component in components {
            currentPath += "/" + component
            guard let url = URL(string: configuration.baseURL.absoluteString + currentPath) else { continue }

            // 先检查是否存在
            if (try? await fileExists(at: currentPath)) == true { continue }

            var request = makeRequest(url: url, method: "MKCOL")
            let (_, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode != 201 && httpResponse.statusCode != 405 {
                // 405 表示已存在，忽略
                if let error = parseHTTPError(response, body: nil) { throw error }
            }
        }
    }

    public func delete(at path: String) async throws {
        guard let url = URL(string: configuration.baseURL.absoluteString + path) else {
            throw StorageError.invalidConfiguration("Invalid path: \(path)")
        }
        var request = makeRequest(url: url, method: "DELETE")
        let (data, response) = try await session.data(for: request)
        if let error = parseHTTPError(response, body: data) { throw error }
    }

    // MARK: - 私有辅助

    private func handleOverwritePolicy(_ uploadRequest: UploadRequest) async throws {
        switch uploadRequest.overwritePolicy {
        case .overwrite: break
        case .skip:
            if try await fileExists(at: uploadRequest.remotePath) { return }
        case .fail:
            if try await fileExists(at: uploadRequest.remotePath) {
                throw StorageError.fileAlreadyExists(path: uploadRequest.remotePath)
            }
        case .rename:
            break  // 由上层 CameraUploadService 处理重命名
        }
    }

    private func parseMultiStatusResponse(data: Data, basePath: String) -> [RemoteFileInfo] {
        // 简化解析：实际项目中建议用 XMLParser 或 SwiftyXML
        guard let xml = String(data: data, encoding: .utf8) else { return [] }

        var results: [RemoteFileInfo] = []
        // 按 <response> 分割解析（生产环境建议用 XMLParser）
        let responses = xml.components(separatedBy: "<D:response>").dropFirst()
        for response in responses {
            guard let hrefRange = response.range(of: "<D:href>"),
                  let hrefEnd = response.range(of: "</D:href>") else { continue }
            let path = String(response[hrefRange.upperBound..<hrefEnd.lowerBound])
                .removingPercentEncoding ?? ""
            let name = (path as NSString).lastPathComponent
            guard !name.isEmpty else { continue }

            let size: Int64 = extractXMLValue(from: response, tag: "D:getcontentlength")
                .flatMap { Int64($0) } ?? 0
            let isDir = response.contains("<D:collection")
            let etag = extractXMLValue(from: response, tag: "D:getetag")
            let contentType = extractXMLValue(from: response, tag: "D:getcontenttype")

            results.append(RemoteFileInfo(
                path: path, name: name, size: size,
                modifiedAt: .now, etag: etag,
                contentType: contentType, isDirectory: isDir
            ))
        }
        return results
    }

    private func extractXMLValue(from xml: String, tag: String) -> String? {
        guard let start = xml.range(of: "<\(tag)>"),
              let end = xml.range(of: "</\(tag)>") else { return nil }
        return String(xml[start.upperBound..<end.lowerBound])
    }
}
