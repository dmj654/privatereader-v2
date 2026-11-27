import Foundation

/// 在线书加入书架时把源站封面落盘。
///
/// 书架只认本地封面文件，不能直接依赖源站 URL：离线、换网络、源站防盗链
/// 都会让书架变成一片灰块。这里只做一次下载 + 归一化，失败就保留占位，
/// 不阻断加入书架。
public enum OnlineCoverStore {
    public static func download(urlString: String,
                                baseURL: String? = nil,
                                headers: [String: String] = [:],
                                bookID: String,
                                paths: SandboxPaths,
                                timeout: TimeInterval = 20) async -> String? {
        guard !urlString.isEmpty,
              var url = URL(string: urlString) else { return nil }
        if url.scheme == nil, let baseURL, let base = URL(string: baseURL) {
            url = URL(string: urlString, relativeTo: base).absoluteURL
        }
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) "
                + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  !data.isEmpty else { return nil }
            let destination = paths.coverFile(bookID)
            guard CoverStore.write(from: data, to: destination) else { return nil }
            return "Covers/\(bookID).jpg"
        } catch {
            return nil
        }
    }
}
