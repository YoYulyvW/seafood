import Foundation
import UIKit
import CryptoKit

struct UpdateInfo: Codable, Equatable {
    var version: String
    var build: Int
    var notes: String
    var ipaURL: String
    var minIOS: String
    var size: Int64
    var sha256: String

    enum CodingKeys: String, CodingKey {
        case version, build, notes, minIOS = "min_ios", size, sha256
        case ipaURL = "ipa_url"
    }
}

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published var checking = false
    @Published var downloading = false
    @Published var progress: Double = 0
    @Published var latest: UpdateInfo?
    @Published var errorText: String?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    var currentBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1") ?? 1
    }

    private var baseURL: URL? {
        let raw = SQLiteStore.shared.setting("update_url").trimmingCharacters(in: .whitespacesAndNewlines)
        let value = raw.isEmpty ? "https://backups.lyvw.top:4433" : raw
        return URL(string: value)
    }

    func check() async {
        guard let base = baseURL else { errorText = "更新地址不合法"; return }
        checking = true
        errorText = nil
        defer { checking = false }
        do {
            var request = URLRequest(url: base.appendingPathComponent("api/app/latest"))
            request.timeoutInterval = 12
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw InventoryError.message("更新服务返回异常")
            }
            let info = try JSONDecoder().decode(UpdateInfo.self, from: data)
            latest = info
        } catch {
            errorText = "检查更新失败：\(error.localizedDescription)"
        }
    }

    var hasUpdate: Bool {
        guard let latest else { return false }
        if latest.build != currentBuild { return latest.build > currentBuild }
        return latest.version.compare(currentVersion, options: .numeric) == .orderedDescending
    }

    /// 下载到临时目录，校验大小与 sha256；返回本地文件。
    func download(_ info: UpdateInfo) async throws -> URL {
        guard let url = URL(string: info.ipaURL) else { throw InventoryError.message("下载地址不合法") }
        downloading = true
        progress = 0
        defer { downloading = false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        let (tempURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw InventoryError.message("下载失败（HTTP 未 200）")
        }
        let name = "Seafood-\(info.version)-b\(info.build).ipa"
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tempURL, to: dest)
        progress = 1
        if info.size > 0 {
            let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            if size != info.size {
                throw InventoryError.message("安装包大小不符（\(size) ≠ \(info.size)）")
            }
        }
        if !info.sha256.isEmpty {
            let digest = try SHA256.hash(file: dest)
            if digest.lowercased() != info.sha256.lowercased() {
                throw InventoryError.message("安装包校验失败（sha256 不符）")
            }
        }
        return dest
    }

    /// 交给 TrollStore 安装：TrollStore 的 URL scheme 会接管下载/安装。
    func installWithTrollStore(_ info: UpdateInfo, localFile: URL?) async throws {
        let remote = URL(string: info.ipaURL)
        let candidates: [URL] = [
            remote.flatMap { trollURL(for: $0) },
            localFile.flatMap { trollURL(for: $0) }
        ].compactMap { $0 }

        for url in candidates where UIApplication.shared.canOpenURL(url) {
            let opened = await UIApplication.shared.open(url)
            if opened { return }
        }
        if let remote {
            await UIApplication.shared.open(remote)
            return
        }
        throw InventoryError.message("没有找到可用的 TrollStore，请手动安装")
    }

    private func trollURL(for url: URL) -> URL? {
        var components = URLComponents()
        components.scheme = "apple-magnifier"
        components.host = "install"
        components.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        return components.url
    }
}

enum SHA256 {
    static func hash(file url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = CryptoKit.SHA256()
        while autoreleasepool(invoking: {
            let chunk = try? handle.read(upToCount: 1 << 20)
            guard let data = chunk, !data.isEmpty else { return false }
            hasher.update(data: data)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
