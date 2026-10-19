import Foundation

/// Intercepts `URLSession` traffic so the real networking methods can be driven
/// end to end without a network, an API key or a Jira tenant.
///
/// This is what makes the otherwise-unverifiable parts testable: the request headers,
/// the body actually put on the wire, and the client's handling of each response.
final class StubURLProtocol: URLProtocol {
    struct Stub {
        var statusCode: Int = 200
        var body: Data = Data()
        var error: Error?
        var headers: [String: String] = ["Content-Type": "application/json"]

        static func json(_ string: String, status: Int = 200) -> Stub {
            Stub(statusCode: status, body: Data(string.utf8))
        }

        static func failure(_ error: Error) -> Stub {
            Stub(error: error)
        }
    }

    private static let lock = NSLock()
    private static var queuedStubs: [Stub] = []
    private static var captured: [URLRequest] = []
    private static var capturedBodies: [Data] = []

    // MARK: - Test control

    /// Stubs are consumed in order, so a two-call flow (create, then attach) can be
    /// given two different responses.
    static func enqueue(_ stubs: Stub...) {
        lock.lock()
        defer { lock.unlock() }
        queuedStubs.append(contentsOf: stubs)
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        queuedStubs = []
        captured = []
        capturedBodies = []
    }

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    /// `URLProtocol` strips `httpBody` from the request it hands us, so bodies are
    /// captured separately via the body stream.
    static var bodies: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return capturedBodies
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func nextStub() -> Stub {
        lock.lock()
        defer { lock.unlock() }
        guard !queuedStubs.isEmpty else { return Stub() }
        return queuedStubs.removeFirst()
    }

    private static func record(_ request: URLRequest, body: Data) {
        lock.lock()
        defer { lock.unlock() }
        captured.append(request)
        capturedBodies.append(body)
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.record(request, body: Self.body(of: request))

        let stub = Self.nextStub()
        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// `httpBody` is nil by the time a protocol sees the request, so fall back to
    /// draining `httpBodyStream`.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }

        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
