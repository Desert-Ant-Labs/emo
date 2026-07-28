import Foundation
import Testing
@testable import Emo
import Inference

#if canImport(CoreML)
import EmoCoreMLResources
#elseif os(Linux) || os(Windows)
import EmoTFLiteResources
#endif

#if canImport(Glibc)
import Glibc
#endif

/// End-to-end check that running an Emo suggestion propagates a usage turnstile
/// all the way through desert-ant-core: the tracked inference session opens a
/// turnstile, records the call, and the `Usage` transport POSTs the wire body.
///
/// The `Usage` transport is fire-and-forget against a fixed ingest endpoint, so
/// this test uses the two supported diagnostic hooks:
///   - `DAL_INGEST_ENDPOINT` redirects the POST to a local capture server, and
///   - `DAL_HTTP_DEBUG` installs the force-flush + await-send hooks so we can
///     make the debounced send go out now and wait for it to land.
///
/// Only runs where the native URLSession transport exists (Apple/Linux).
#if canImport(CoreML) || os(Linux)
struct UsageTests {
    private func makeEmo() -> Emo {
        #if canImport(CoreML)
        return Emo(bundle: EmoCoreMLResourcesBundle.bundle)
        #elseif os(Linux) || os(Windows)
        return Emo(bundle: EmoTFLiteResourcesBundle.bundle)
        #else
        fatalError("no bundled model for this platform")
        #endif
    }

    @Test func suggestionEmitsUsageThroughCore() async throws {
        let server = try CaptureServer()
        defer { server.stop() }

        setenv("DAL_INGEST_ENDPOINT", "http://127.0.0.1:\(server.port)/api/v1/ingest", 1)
        setenv("DAL_HTTP_DEBUG", "1", 1)
        defer {
            unsetenv("DAL_INGEST_ENDPOINT")
            unsetenv("DAL_HTTP_DEBUG")
        }

        let emo = makeEmo()
        let results = try await emo.suggestions(for: "Pay my bills", limit: 3)
        #expect(results.count == 3)

        await TelemetryDebug.shared.flushAndWait()

        let body = try await server.awaitBody(timeout: 5)
        let ingest = try JSONDecoder().decode(IngestBody.self, from: body)

        #expect(ingest.platform == defaultPlatform)
        #expect(["com.apple.dt.xctest.tool", "swiftpm-testing-helper"].contains(ingest.app?.id))
        #expect(ingest.sdk.name == "Emo")
        #expect(ingest.sdk.version == emoSDKVersion)
        #expect(!ingest.events.isEmpty)

        let load = try #require(ingest.events.first)
        #expect(load.name == "load")
        #expect(!load.deviceId.isEmpty)
        #expect((load.callCount ?? 0) >= 1)
    }

    /// Several runs wrapped in `InferenceContext.withCallGroup` bill as a single
    /// usage call; the same runs without a group bill individually. Uses a fresh
    /// app id (turnstile namespace) per case so the turnstile actually emits, and
    /// lets the debounce flush send — no forced-flush debug path to skew counts.
    @Test func callGroupCoalescesRunsIntoOneCall() async throws {
        // Grouped: three suggestions inside one call group -> callCount == 1.
        let grouped = try await capturedCallCount() { emo in
            try await InferenceContext.withCallGroup {
                for _ in 0..<3 { _ = try await emo.suggestions(for: "Pay my bills", limit: 1) }
            }
        }
        #expect(grouped == 1)

        // Control: the same three suggestions with no group -> callCount == 3.
        let ungrouped = try await capturedCallCount() { emo in
            for _ in 0..<3 { _ = try await emo.suggestions(for: "Pay my bills", limit: 1) }
        }
        #expect(ungrouped == 3)
    }

    /// Run `body` against a fresh Emo whose usage POST is captured locally, and
    /// return the emitted `callCount`. A unique `appId` gives a fresh turnstile
    /// namespace so the load actually emits; the ~3s debounce does the send.
    private func capturedCallCount(
        _ body: (Emo) async throws -> Void
    ) async throws -> Int? {
        let server = try CaptureServer()
        defer { server.stop() }
        setenv("DAL_INGEST_ENDPOINT", "http://127.0.0.1:\(server.port)/api/v1/ingest", 1)
        defer { unsetenv("DAL_INGEST_ENDPOINT") }

        let emo = makeEmo()
        try await body(emo)

        // Wait out the tracked session's debounce (default ~3s) + the send.
        let data = try await server.awaitBody(timeout: 10)
        withExtendedLifetime(emo) {}
        let ingest = try JSONDecoder().decode(IngestBody.self, from: data)
        return try #require(ingest.events.first).callCount
    }
}

/// A minimal, single-request HTTP server over POSIX sockets. It accepts one
/// connection, reads the full request (headers + body via Content-Length), and
/// replies `200 OK`. Enough to capture the usage POST in a test.
private final class CaptureServer: @unchecked Sendable {
    let port: UInt16
    private let listenFD: Int32
    private let lock = NSLock()
    private var captured: Data?
    private var running = true

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM_VALUE, 0)
        guard fd >= 0 else { throw ServerError.socket }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // ask the OS for an ephemeral port
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { close(fd); throw ServerError.bind }
        guard listen(fd, 1) == 0 else { close(fd); throw ServerError.listen }

        // Read back the assigned port.
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        port = UInt16(bigEndian: bound.sin_port)
        listenFD = fd

        Thread.detachNewThread { [fd] in self.serve(fd) }
    }

    private func serve(_ fd: Int32) {
        let clientFD = accept(fd, nil, nil)
        guard clientFD >= 0 else { return }
        defer { close(clientFD) }

        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        var headerEnd: Range<Data.Index>?

        // Read until we have the header terminator, then the full body.
        while running {
            let n = read(clientFD, &buffer, buffer.count)
            if n <= 0 { break }
            request.append(contentsOf: buffer[0..<n])

            if headerEnd == nil {
                headerEnd = request.range(of: Data("\r\n\r\n".utf8))
            }
            if let he = headerEnd {
                let header = String(decoding: request[request.startIndex..<he.lowerBound], as: UTF8.self)
                let contentLength = Self.contentLength(header) ?? 0
                let bodyStart = he.upperBound
                if request.distance(from: bodyStart, to: request.endIndex) >= contentLength {
                    let body = request[bodyStart..<request.index(bodyStart, offsetBy: contentLength)]
                    setCaptured(Data(body))
                    break
                }
            }
        }

        let response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        _ = response.utf8.withContiguousStorageIfAvailable { ptr in
            write(clientFD, ptr.baseAddress, ptr.count)
        }
    }

    private static func contentLength(_ header: String) -> Int? {
        for line in header.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                return Int(parts[1].trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    private func setCaptured(_ data: Data) {
        lock.lock(); captured = data; lock.unlock()
    }

    private func takeCaptured() -> Data? {
        lock.lock(); defer { lock.unlock() }; return captured
    }

    func awaitBody(timeout: TimeInterval) async throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let body = takeCaptured() { return body }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw ServerError.timeout
    }

    func stop() {
        running = false
        close(listenFD)
    }

    enum ServerError: Error { case socket, bind, listen, timeout }
}

// SOCK_STREAM is an enum on Darwin and a raw Int32 on Glibc; normalize it.
#if canImport(Glibc)
private let SOCK_STREAM_VALUE = Int32(SOCK_STREAM.rawValue)
#else
private let SOCK_STREAM_VALUE = SOCK_STREAM
#endif
#endif
