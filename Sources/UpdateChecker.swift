import Foundation

/// Asks GitHub for the latest release. Uses a throwaway ephemeral session so
/// no cache or cookies persist, and sends no user or device data.
enum UpdateChecker {
    static func fetchLatest(completion: @escaping (Result<ReleaseInfo, Error>) -> Void) {
        guard let url = URL(string: "https://api.github.com/repos/\(ReleaseInfo.repository)/releases/latest") else { return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("wifi-static-ip-mute-switcher", forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        session.dataTask(with: request) { data, response, error in
            let result: Result<ReleaseInfo, Error>
            if let error { result = .failure(error) }
            else if (response as? HTTPURLResponse)?.statusCode != 200 { result = .failure(UpdateError.status((response as? HTTPURLResponse)?.statusCode ?? 0)) }
            else if let data, let release = ReleaseInfo.parse(data) { result = .success(release) }
            else { result = .failure(UpdateError.invalidResponse) }
            DispatchQueue.main.async { completion(result) }
        }.resume()
        session.finishTasksAndInvalidate()
    }

    enum UpdateError: LocalizedError {
        case status(Int), invalidResponse
        var errorDescription: String? {
            switch self {
            case let .status(code): return "GitHub 返回 \(code)"
            case .invalidResponse: return "无法解析版本信息"
            }
        }
    }
}

enum UpdateState: Equatable {
    case idle, checking, upToDate
    case available(ReleaseInfo)
    case failed(String)
}
