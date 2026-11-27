import Foundation
@testable import CollabDockCore

/// 进程内假 GitHub API：按「方法 + 路径」路由，记录全部请求，未命中的路由返回 404 并记录下来供断言。
final class FakeGitHub: HTTPTransport, @unchecked Sendable {
    struct Response {
        var status: Int = 200
        var body: String = "{}"
        var headers: [String: String] = [:]
    }

    struct RecordedRequest {
        let method: String
        let path: String
        let query: String
        let headers: [String: String]
        let body: Data?

        var jsonBody: [String: Any]? {
            body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
    }

    private let lock = NSLock()
    private var routes: [String: (URLRequest) -> Response] = [:]
    private var recorded: [RecordedRequest] = []
    private var unmatched: [String] = []

    func on(_ method: String, _ path: String, _ handler: @escaping (URLRequest) -> Response) {
        lock.lock(); defer { lock.unlock() }
        routes["\(method) \(path)"] = handler
    }

    func on(_ method: String, _ path: String, json: String, status: Int = 200, headers: [String: String] = [:]) {
        on(method, path) { _ in Response(status: status, body: json, headers: headers) }
    }

    var requests: [RecordedRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    var unmatchedRequests: [String] {
        lock.lock(); defer { lock.unlock() }
        return unmatched
    }

    private func record(_ request: RecordedRequest, key: String) -> ((URLRequest) -> Response)? {
        lock.withLock {
            recorded.append(request)
            let handler = routes[key]
            if handler == nil { unmatched.append(key) }
            return handler
        }
    }

    func requests(_ method: String, _ path: String) -> [RecordedRequest] {
        requests.filter { $0.method == method && $0.path == path }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        let key = "\(method) \(path)"
        let handler = record(
            RecordedRequest(
                method: method,
                path: path,
                query: request.url?.query.flatMap { $0.removingPercentEncoding } ?? "",
                headers: request.allHTTPHeaderFields ?? [:],
                body: request.httpBody
            ),
            key: key
        )

        let response = handler?(request) ?? Response(status: 404, body: #"{"message":"Not Found"}"#)
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: response.headers
        )!
        return (Data(response.body.utf8), http)
    }
}

struct StaticTokenProvider: GitHubTokenProvider {
    let token: String
    func fetchToken() async -> String? { token }
}
