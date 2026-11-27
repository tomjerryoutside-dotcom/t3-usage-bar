import Foundation

enum AntigravityQuota {
    private struct Settings: Decodable {
        struct Source: Decodable {
            let enabled: Bool?
            let kind: String
            let url: URL?

            var localQuotaURL: URL? {
                guard enabled != false, kind == "http", let url,
                      url.scheme == "http", url.host == "127.0.0.1", url.port != nil,
                      url.path == "/antigravity", url.user == nil, url.password == nil,
                      url.query == nil, url.fragment == nil else { return nil }
                return url
            }
        }

        let usageLimitSources: [String: Source]?
    }

    private struct Response: Decodable {
        struct Account: Decodable {
            let label: String
            let providerInstanceId: String
            let windows: [Quota]
        }

        let version: Int
        let accounts: [Account]
    }

    private final class LocalOnly: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static let relevantWindows: Set<String> = ["gemini-5h", "gemini-weekly", "3p-5h", "3p-weekly"]
    private static let planLabels = [
        "Google AI Plus": "Google AI Plus",
        "Google AI Pro": "Google AI Pro",
        "Google AI Ultra 5x": "Google AI Ultra 5×",
        "Google AI Ultra 20x": "Google AI Ultra 20×"
    ]

    static func read(home: URL = FileManager.default.homeDirectoryForCurrentUser) async throws -> QuotaSnapshot? {
        let path = home.appendingPathComponent(".t3/userdata/settings.json")
        guard let data = try? Data(contentsOf: path),
              let settings = try? JSONDecoder().decode(Settings.self, from: data),
              let url = settings.usageLimitSources?.values.compactMap(\.localQuotaURL).first else { return nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0]
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 9
        let session = URLSession(configuration: configuration, delegate: LocalOnly(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (body, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }

        let receipt = try JSONDecoder().decode(Response.self, from: body)
        guard receipt.version == 1,
              let account = receipt.accounts.first(where: { $0.providerInstanceId == "antigravity" }) else {
            throw URLError(.cannotParseResponse)
        }
        let windows = account.windows.filter { relevantWindows.contains($0.id) }
        guard !windows.isEmpty else { throw URLError(.cannotParseResponse) }
        let plan = http.value(forHTTPHeaderField: "X-Antigravity-Plan").flatMap { planLabels[$0] }
        if let range = account.label.range(of: "上次读取") {
            return QuotaSnapshot(
                checkedAt: nil, windows: windows, source: String(account.label[range.lowerBound...]), plan: plan
            )
        }
        return QuotaSnapshot(
            checkedAt: ISO8601DateFormatter().string(from: Date()), windows: windows, source: "自动同步", plan: plan
        )
    }
}
