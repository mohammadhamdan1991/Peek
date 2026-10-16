#if !PEEK_DISABLED
import Foundation
import Testing
@testable import PeekCore

private func record(bytes: Int = 0, id: UUID = UUID(), status: Int? = nil) -> HTTPRecord {
    HTTPRecord(
        id: id,
        method: "GET",
        url: URL(string: "https://api.staging.example.com/v1/x")!,
        statusCode: status,
        responseBody: bytes > 0 ? CapturedBody(Data(count: bytes)) : nil
    )
}

@Suite struct RecordStoreTests {
    @Test func startsPausedAndIgnoresRecords() {
        let store = RecordStore<HTTPRecord>(limits: .init(count: 10, bytes: 1_000))
        store.record(record())
        #expect(store.records.isEmpty)
    }

    @Test func evictsOldestPastCountLimit() {
        let store = RecordStore<HTTPRecord>(limits: .init(count: 3, bytes: 1_000), isPaused: false)
        let ids = (0..<5).map { _ in UUID() }
        ids.forEach { store.record(record(id: $0)) }
        #expect(store.records.map(\.id) == Array(ids.suffix(3)))
    }

    @Test func evictsOldestPastByteBudget() {
        let store = RecordStore<HTTPRecord>(limits: .init(count: 100, bytes: 250), isPaused: false)
        let ids = (0..<3).map { _ in UUID() }
        ids.forEach { store.record(record(bytes: 100, id: $0)) }
        #expect(store.records.map(\.id) == Array(ids.suffix(2)))
        #expect(store.byteCount == 200)
    }

    @Test func replacesRecordWithSameIdAndRebalancesBytes() {
        let store = RecordStore<HTTPRecord>(limits: .init(count: 10, bytes: 1_000), isPaused: false)
        let id = UUID()
        store.record(record(id: id))
        store.record(record(bytes: 120, id: id, status: 200))
        #expect(store.records.count == 1)
        #expect(store.records.first?.statusCode == 200)
        #expect(store.byteCount == 120)
    }

    @Test func clearEmptiesStore() {
        let store = RecordStore<HTTPRecord>(limits: .init(count: 10, bytes: 1_000), isPaused: false)
        store.record(record(bytes: 10))
        store.clear()
        #expect(store.records.isEmpty)
        #expect(store.byteCount == 0)
    }

    @Test func notifiesObservers() async {
        let store = RecordStore<HTTPRecord>(limits: .init(count: 10, bytes: 1_000), isPaused: false)
        var iterator = store.updates().makeAsyncIterator()
        store.record(record())
        #expect(await iterator.next() != nil)
    }
}

@Suite struct CapturedBodyTests {
    @Test func truncatesPastLimit() {
        let body = CapturedBody(Data(count: 10), limit: 4)
        #expect(body.data.count == 4)
        #expect(body.originalSize == 10)
        #expect(body.isTruncated)
    }

    @Test func keepsSmallBodies() {
        let body = CapturedBody(Data([1, 2, 3]), limit: 4)
        #expect(body.data == Data([1, 2, 3]))
        #expect(!body.isTruncated)
    }
}

@Suite struct RedactorTests {
    let redactor = Redactor.default

    @Test func redactsSensitiveHeadersCaseInsensitively() {
        let headers = redactor.redact(headers: ["authorization": "Bearer abc", "Accept": "application/json"])
        #expect(headers["authorization"] == Redactor.mask)
        #expect(headers["Accept"] == "application/json")
    }

    @Test func redactsQueryItems() {
        let url = redactor.redact(url: URL(string: "https://x.io/a?access_token=abc&page=2")!)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        #expect(items?.first { $0.name == "access_token" }?.value == Redactor.mask)
        #expect(items?.first { $0.name == "page" }?.value == "2")
    }

    @Test func redactsNestedJSONKeysInAnyCase() throws {
        let body = Data(#"{"session":{"accessToken":"abc","refresh_token":"def"},"cardNumber":"4111","items":[{"pin":"1234","name":"ok"}]}"#.utf8)
        let json = try #require(try JSONSerialization.jsonObject(with: redactor.redact(body: body)) as? [String: Any])
        let session = try #require(json["session"] as? [String: Any])
        #expect(session["accessToken"] as? String == Redactor.mask)
        #expect(session["refresh_token"] as? String == Redactor.mask)
        #expect(json["cardNumber"] as? String == Redactor.mask)
        let item = try #require((json["items"] as? [[String: Any]])?.first)
        #expect(item["pin"] as? String == Redactor.mask)
        #expect(item["name"] as? String == "ok")
    }

    @Test func redactsPhonesAndEmailsInsideStrings() {
        let text = String(decoding: redactor.redact(body: Data("call +213 555 12 34 56 or 0555123456, mail a.b@example.com, trip 1697040000123".utf8)), as: UTF8.self)
        #expect(!text.contains("555"))
        #expect(!text.contains("example.com"))
        #expect(text.contains("1697040000123"))
    }

    @Test func leavesBinaryBodiesAlone() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0xFF, 0xFE])
        #expect(redactor.redact(body: png) == png)
    }
}

@Suite struct HTTPCaptureTests {
    let store = RecordStore<HTTPRecord>(limits: .init(count: 10, bytes: 10 * 1_048_576), isPaused: false)
    let capture: HTTPCapture
    init() { capture = HTTPCapture(store: store) }
    let url = URL(string: "https://api.staging.example.com/v2/driver/location?token=abc")!

    private func start(_ id: UUID) {
        capture.started(id: id, correlationID: nil, startedAt: Date(), method: "POST", url: url,
                        headers: ["Authorization": "Bearer x"], body: Data(#"{"password":"p","lat":1}"#.utf8))
    }

    @Test func startedRecordIsRedacted() throws {
        let id = UUID()
        start(id)
        capture.flush()
        let record = try #require(store.records.first)
        #expect(record.requestHeaders["Authorization"] == Redactor.mask)
        #expect(!record.url.absoluteString.contains("abc"))
        let body = String(decoding: try #require(record.requestBody).data, as: UTF8.self)
        #expect(!body.contains("\"p\""))
        #expect(!record.isComplete)
    }

    @Test func laterFailureKeepsTheResponse() throws {
        let id = UUID()
        start(id)
        capture.finished(id: id, correlationID: nil, method: "POST", url: url, statusCode: 200,
                         headers: ["Content-Type": "application/json"], body: Data("{}".utf8), error: nil, duration: 0.2)
        capture.finished(id: id, correlationID: nil, method: "POST", url: url, statusCode: nil,
                         headers: nil, body: nil, error: "DecodingError.keyNotFound", duration: 0.3)
        capture.flush()
        let record = try #require(store.records.first)
        #expect(store.records.count == 1)
        #expect(record.statusCode == 200)
        #expect(record.responseBody?.data == Data("{}".utf8))
        #expect(record.error == "DecodingError.keyNotFound")
        #expect(record.isFailure)
    }

    @Test func failureWithoutStartCreatesARecord() throws {
        capture.finished(id: UUID(), correlationID: nil, method: "GET", url: url, statusCode: nil,
                         headers: nil, body: nil, error: "EncodingError", duration: 0)
        capture.flush()
        #expect(store.records.first?.error == "EncodingError")
    }

    @Test func hugeBodiesAreDroppedNotStoredUnredacted() throws {
        let id = UUID()
        capture.started(id: id, correlationID: nil, startedAt: Date(), method: "POST", url: url,
                        headers: nil, body: Data(count: HTTPCapture.redactableLimit + 1))
        capture.flush()
        let body = String(decoding: try #require(store.records.first?.requestBody).data, as: UTF8.self)
        #expect(body.contains("too large to redact"))
    }

    @Test func timingAddsTheWaitingPhase() throws {
        let t0 = Date()
        let timing = HTTPTiming(
            domainLookup: DateInterval(start: t0, duration: 0.01), connect: nil, secureConnection: nil,
            request: DateInterval(start: t0.addingTimeInterval(0.02), duration: 0.01),
            response: DateInterval(start: t0.addingTimeInterval(0.5), duration: 0.1),
            networkProtocol: "h2", isReusedConnection: false
        )
        #expect(timing.phases.map(\.name) == ["DNS", "Request", "Waiting", "Response"])
        let waiting = try #require(timing.phases.first { $0.name == "Waiting" })
        #expect(abs(waiting.interval.duration - 0.47) < 0.001)
        #expect(abs(try #require(timing.total).duration - 0.6) < 0.001)
    }

    @Test func updateEvictsWhenARecordGrowsPastTheBudget() {
        let small = RecordStore<HTTPRecord>(limits: .init(count: 10, bytes: 150), isPaused: false)
        let first = UUID(), second = UUID()
        small.record(record(bytes: 100, id: first))
        small.record(record(id: second))
        small.update(id: second) { $0.responseBody = CapturedBody(Data(count: 100)) }
        #expect(small.records.map(\.id) == [second])
    }
}

@Suite struct NetworkQueryTests {
    private func make(_ url: String, status: Int? = 200, error: String? = nil, module: String? = nil, body: String? = nil) -> HTTPRecord {
        make("GET", url, status: status, error: error, module: module, body: body)
    }

    private func make(_ method: String, _ url: String, status: Int? = 200, error: String? = nil, module: String? = nil, body: String? = nil) -> HTTPRecord {
        HTTPRecord(module: module, method: method, url: URL(string: url)!, statusCode: status,
                   responseBody: body.map { CapturedBody(Data($0.utf8)) }, error: error)
    }

    @Test func parsesTokensAndFreeText() {
        let query = NetworkQuery("status:5xx  host:Example trips Today method:")
        #expect(query.tokens == [.init(key: "status", value: "5xx"), .init(key: "host", value: "example")])
        #expect(query.text == "trips today method:")
    }

    @Test func statusTokens() {
        let r503 = make("https://api.example.com/a", status: 503)
        let r404 = make("https://api.example.com/a", status: 404)
        let failed = make("https://api.example.com/a", status: nil, error: "URLError(-1009)")
        #expect(NetworkQuery("status:5xx").matches(r503))
        #expect(!NetworkQuery("status:5xx").matches(r404))
        #expect(NetworkQuery("status:404").matches(r404))
        #expect(NetworkQuery("status:failed").matches(failed))
        #expect(!NetworkQuery("status:failed").matches(r503))
    }

    @Test func hostMethodModuleAndText() {
        let record = make("POST", "https://api.staging.example.com/v2/driver/trips", module: "Driver", body: #"{"tripId":"7F3A"}"#)
        #expect(NetworkQuery("host:staging method:post module:driver").matches(record))
        #expect(!NetworkQuery("method:get").matches(record))
        #expect(NetworkQuery("7f3a").matches(record))
        #expect(!NetworkQuery("earnings").matches(record))
    }

    @Test func errorsOnly() {
        #expect(!NetworkQuery(errorsOnly: true).matches(make("https://a.io", status: 200)))
        #expect(NetworkQuery(errorsOnly: true).matches(make("https://a.io", status: 401)))
    }

    @Test func statusClasses() {
        #expect(StatusClass(make("https://a.io", status: nil)) == .pending)
        #expect(StatusClass(make("https://a.io", status: 200, error: "DecodingError")) == .failed)
        #expect(StatusClass(make("https://a.io", status: 304)) == .redirect)
        #expect(StatusClass(make("https://a.io", status: 502)) == .serverError)
    }
}

@Suite struct RedactionPolicyTests {
    @Test func storesTheRedactedCopyAndKeepsTheRealValues() throws {
        let store = RecordStore<HTTPRecord>(limits: .init(count: 10, bytes: 1_048_576), isPaused: false)
        let capture = HTTPCapture(store: store)
        let url = URL(string: "https://a.io/x?access_token=abc")!
        let body = Data(#"{"password":"p"}"#.utf8)
        capture.started(id: UUID(), correlationID: nil, startedAt: Date(), method: "POST", url: url,
                        headers: ["Authorization": "Bearer real"], body: body)
        capture.flush()
        let stored = try #require(store.records.first)
        #expect(stored.requestHeaders["Authorization"] == Redactor.mask)
        #expect(stored.isRedacted && !stored.curlCommand.contains("Bearer real"))

        // Switching redaction off later reveals what was already captured.
        let real = stored.revealed()
        #expect(real.requestHeaders["Authorization"] == "Bearer real")
        #expect(real.url == url)
        #expect(real.requestBody?.data == body)
        #expect(!real.isRedacted)
        #expect(real.report(.markdown).contains("redaction OFF"))
        #expect(real.curlCommand.contains("Bearer real"))
        #expect(stored.displayed(redacted: true).requestHeaders["Authorization"] == Redactor.mask)
    }

    @Test func revealsTheResponseToo() throws {
        let store = RecordStore<HTTPRecord>(limits: .init(count: 10, bytes: 1_048_576), isPaused: false)
        let capture = HTTPCapture(store: store)
        let id = UUID()
        capture.started(id: id, correlationID: nil, startedAt: Date(), method: "GET", url: URL(string: "https://a.io")!,
                        headers: nil, body: nil)
        capture.finished(id: id, correlationID: nil, method: "GET", url: nil, statusCode: 200,
                         headers: ["Set-Cookie": "s=1"], body: Data(#"{"token":"t"}"#.utf8), error: nil, duration: 0.1)
        capture.flush()
        let stored = try #require(store.records.first)
        #expect(stored.responseHeaders["Set-Cookie"] == Redactor.mask)
        #expect(stored.revealed().responseHeaders["Set-Cookie"] == "s=1")
        #expect(stored.revealed().responseBody?.data == Data(#"{"token":"t"}"#.utf8))
    }
}

@Suite struct SocketTests {
    @Test func captureRedactsPayloadAndKeepsOrder() throws {
        let store = RecordStore<SocketRecord>(limits: .init(count: 10, bytes: 1_048_576), isPaused: false)
        let capture = SocketCapture(store: store)
        capture.record(id: UUID(), date: Date(), url: "https://socket.example.com?token=abc", namespace: "/driver",
                       direction: .lifecycle, name: "connect", payload: Data(#"["/driver"]"#.utf8), payloadDescription: nil)
        capture.record(id: UUID(), date: Date(), url: "https://socket.example.com", namespace: "/driver",
                       direction: .incoming, name: "trip.status_changed",
                       payload: Data(#"[{"tripId":"7f3a","rider":{"phone":"0555123456"},"accessToken":"x"}]"#.utf8), payloadDescription: nil)
        capture.flush()
        #expect(store.records.map(\.name) == ["connect", "trip.status_changed"])
        #expect(!(store.records[0].url?.absoluteString.contains("abc") ?? true))
        let payload = String(decoding: try #require(store.records[1].payload).data, as: UTF8.self)
        #expect(payload.contains("7f3a"))
        #expect(!payload.contains("0555123456"))
        #expect(!payload.contains("\"x\""))
    }

    @Test func queryMatching() {
        let record = SocketRecord(url: URL(string: "https://socket.example.com"), namespace: "/driver",
                                  direction: .incoming, name: "ride.request", payload: CapturedBody(Data(#"[{"fare":640}]"#.utf8)))
        #expect(NetworkQuery("ride").matches(record))
        #expect(NetworkQuery("640").matches(record))
        #expect(NetworkQuery("host:socket method:ws").matches(record))
        #expect(!NetworkQuery("status:5xx").matches(record))
        #expect(!NetworkQuery(errorsOnly: true).matches(record))
        #expect(NetworkQuery(errorsOnly: true).matches(SocketRecord(url: nil, namespace: "/", direction: .lifecycle, name: "error", payload: nil)))
    }
}

@Suite struct ExportTests {
    let record = HTTPRecord(
        method: "POST",
        url: URL(string: "https://api.example.com/v1/x?page=2")!,
        requestHeaders: ["Content-Type": "application/json"],
        requestBody: CapturedBody(Data(#"{"name":"O'Neil"}"#.utf8)),
        statusCode: 201,
        responseBody: CapturedBody(Data("{}".utf8)),
        duration: 0.25
    )

    @Test func curlQuotesSafely() {
        let curl = record.curlCommand
        #expect(curl.hasPrefix("curl -X POST 'https://api.example.com/v1/x?page=2'"))
        #expect(curl.contains("-H 'Content-Type: application/json'"))
        #expect(curl.contains(#"--data-raw '{"name":"O'\''Neil"}'"#))
    }

    @Test func harIsValidJSONWithOneEntry() throws {
        let json = try #require(try JSONSerialization.jsonObject(with: HAR.export([record, HTTPRecord(method: "GET", url: URL(string: "https://a.io")!)])) as? [String: Any])
        let entries = try #require((json["log"] as? [String: Any])?["entries"] as? [[String: Any]])
        #expect(entries.count == 2)
        let request = try #require(entries[0]["request"] as? [String: Any])
        #expect(request["method"] as? String == "POST")
        #expect((request["postData"] as? [String: Any])?["text"] as? String == #"{"name":"O'Neil"}"#)
        #expect((entries[0]["response"] as? [String: Any])?["status"] as? Int == 201)
        #expect(entries[0]["time"] as? Double == 250)
        #expect((entries[1]["request"] as? [String: Any])?["postData"] == nil)
    }
}

@Suite struct ReportTests {
    let record = HTTPRecord(
        method: "POST",
        url: URL(string: "https://api.example.com/v2/trips?page=1")!,
        requestHeaders: ["Content-Type": "application/json"],
        requestBody: CapturedBody(Data(#"{"a":1}"#.utf8)),
        statusCode: 200,
        responseHeaders: ["X-Trace": "abc"],
        responseBody: CapturedBody(Data(#"{"ok":true}"#.utf8)),
        duration: 0.184
    )

    @Test func summaryLine() {
        #expect(record.summaryLine == "POST /v2/trips → 200 OK · 184 ms")
    }

    @Test func markdownReportHasFencedSections() {
        let report = record.report(.markdown)
        #expect(report.hasPrefix("### POST /v2/trips → 200 OK · 184 ms"))
        #expect(report.contains("```http\nContent-Type: application/json\n```"))
        #expect(report.contains("```json\n{\n  \"ok\" : true\n}\n```"))
        #expect(report.contains("```bash\ncurl -X POST"))
        #expect(report.contains("redacted"))
    }

    @Test func plainTextHasNoMarkdown() {
        let report = record.report(.plainText)
        #expect(!report.contains("```"))
        #expect(report.contains("--- Request ---"))
        #expect(report.contains("X-Trace: abc"))
    }

    @Test func failedResponseReportsTheError() {
        let failed = HTTPRecord(method: "GET", url: URL(string: "https://a.io/x")!, error: "URLError(-1009)")
        #expect(failed.summaryLine == "GET /x → failed")
        #expect(failed.responseReport(.markdown).contains("**Error:** `URLError(-1009)`"))
    }

    @Test func logJoinsRecords() {
        #expect(TextLog.export([record, record], style: .markdown).components(separatedBy: "\n\n---\n\n").count == 2)
    }
}

@Suite struct JSONTreeTests {
    let tree = JSONTree(Data(#"{"b":[1,true,null],"a":{"x":"y"}}"#.utf8))!

    @Test func flattensInKeyOrderWithKinds() {
        #expect(tree.lines.map(\.id) == ["$", "$.a", "$.a.x", "$.b", "$.b[0]", "$.b[1]", "$.b[2]"])
        #expect(tree.lines.map(\.kind) == [.object, .object, .string, .array, .number, .bool, .null])
        #expect(tree.lines[3].value == "[ 3 items ]")
        #expect(tree.lines[5].value == "true")
    }

    @Test func collapsingHidesDescendants() {
        #expect(tree.visibleLines(collapsed: ["$.b"]).map(\.id) == ["$", "$.a", "$.a.x", "$.b"])
        #expect(tree.visibleLines(collapsed: ["$"]).map(\.id) == ["$"])
    }

    @Test func nonJSONIsNil() {
        #expect(JSONTree(Data("hello".utf8)) == nil)
    }

    @Test func dottedKeysDontCollide() {
        let ids = JSONTree(Data(#"{"a.b":1,"a":{"b":2}}"#.utf8))!.lines.map(\.id)
        #expect(ids == ["$", "$.a", "$.a.b", #"$["a.b"]"#])
    }
}

@Suite struct InspectorGateTests {
    private func facts(bundle: String? = "app.staging", production: Bool = false, appStore: Bool = false) -> InspectorGate.Facts {
        .init(bundleIdentifier: bundle, allowedBundleIdentifiers: ["app.staging"], isProductionEnvironment: production, isAppStoreInstall: appStore)
    }

    @Test func noAllowlistAllowsAnyBundle() {
        let facts = InspectorGate.Facts(bundleIdentifier: "com.any.app", allowedBundleIdentifiers: nil,
                                        isProductionEnvironment: false, isAppStoreInstall: false)
        #expect(InspectorGate.evaluate(facts) == .allowed)
    }

    @Test func allowsNonProductionAllowlistedBuild() {
        #expect(InspectorGate.evaluate(facts()) == .allowed)
    }

    @Test func deniesProductionEnvironment() {
        #expect(InspectorGate.evaluate(facts(production: true)) == .denied(.productionEnvironment))
    }

    @Test func deniesUnknownOrMissingBundle() {
        #expect(InspectorGate.evaluate(facts(bundle: "app")) == .denied(.bundleNotAllowed))
        #expect(InspectorGate.evaluate(facts(bundle: nil)) == .denied(.bundleNotAllowed))
    }

    @Test func deniesAppStoreInstall() {
        #expect(InspectorGate.evaluate(facts(appStore: true)) == .denied(.appStoreInstall))
    }
}
#endif

@Suite struct ReviewFixTests {
    let redactor = Redactor.default

    @Test func masksTokenShapesHeadersAndForms() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sig_part"
        #expect(!redactor.redact(text: "failed for \(jwt)").contains(jwt))
        #expect(redactor.redact(text: "Bearer abc.def") == "Bearer \(Redactor.mask)")
        #expect(redactor.redact(headers: ["X-Auth-Token": "t"])["X-Auth-Token"] == Redactor.mask)
        let form = String(decoding: redactor.redact(body: Data("user=ali&refresh_token=xyz".utf8)), as: UTF8.self)
        #expect(form.contains("user=ali") && !form.contains("xyz"))
    }

    @Test func redactsJSONInsideStringValues() {
        let body = Data(#"{"data":"{\"email\":\"a@b.co\",\"password\":\"hunter2\"}"}"#.utf8)
        let text = String(decoding: redactor.redact(body: body), as: UTF8.self)
        #expect(!text.contains("hunter2") && !text.contains("a@b.co"))
    }

    @Test func truncatesOnACharacterBoundary() {
        let body = CapturedBody(Data("aé".utf8), limit: 2) // "é" is 2 bytes; a raw cut would split it
        #expect(String(data: body.data, encoding: .utf8) == "a")
        #expect(body.isTruncated)
    }

    @Test func pausingKeepsInFlightResponsesButDropsNewRequests() {
        let store = RecordStore<HTTPRecord>(limits: .init(count: 10, bytes: 1_000_000), isPaused: false)
        let capture = HTTPCapture(store: store)
        let id = UUID()
        capture.started(id: id, correlationID: nil, startedAt: Date(), method: "GET", url: URL(string: "https://a.b")!, headers: nil, body: nil)
        capture.flush()
        store.isPaused = true
        capture.finished(id: id, correlationID: nil, method: "GET", url: nil, statusCode: 200, headers: nil, body: nil, error: nil, duration: 1)
        capture.started(id: UUID(), correlationID: nil, startedAt: Date(), method: "GET", url: URL(string: "https://a.b")!, headers: nil, body: nil)
        capture.flush()
        #expect(store.records.map(\.statusCode) == [200])
    }

    @Test func clearedRequestDoesNotComeBackHalfDone() {
        let store = RecordStore<HTTPRecord>(limits: .init(count: 10, bytes: 1_000_000), isPaused: false)
        let capture = HTTPCapture(store: store)
        capture.finished(id: UUID(), correlationID: nil, method: "GET", url: URL(string: "https://a.b"), statusCode: 200, headers: nil, body: nil, error: nil, duration: 1)
        capture.flush()
        #expect(store.records.isEmpty)
    }
}

/// Answers every request with a fixed 200, so the swizzle test needs no network.
final class StubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"ok":true}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct URLSessionCaptureTests {
    static let store = RecordStore<HTTPRecord>(limits: .init(count: 100, bytes: 1_000_000), isPaused: false)
    static let capture = HTTPCapture(store: store)

    func session(delegate: URLSessionDelegate? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        configuration.httpAdditionalHeaders = ["User-Agent": "Tests"]
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    func run(_ session: URLSession, _ request: URLRequest, upload: Data? = nil) async -> Data? {
        await withCheckedContinuation { done in
            let task = upload.map { body in session.uploadTask(with: request, from: body) { data, _, _ in done.resume(returning: data) } }
                ?? session.dataTask(with: request) { data, _, _ in done.resume(returning: data) }
            task.resume()
        }
    }

    @Test func capturesCompletionHandlerTasksUntouched() async throws {
        URLSessionCapture.install(Self.capture)
        Self.store.clear()
        var request = URLRequest(url: URL(string: "https://example.com/v1/trips?token=abc")!)
        request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        let data = await run(session(), request)
        #expect(data == Data(#"{"ok":true}"#.utf8)) // the caller still gets its response
        try await Task.sleep(for: .milliseconds(100)) // metrics arrive after the completion handler
        Self.capture.flush()

        let record = try #require(Self.store.records.first)
        #expect(Self.store.records.count == 1)
        #expect(record.statusCode == 200)
        #expect(record.requestHeaders["User-Agent"] == "Tests")
        #expect(record.requestHeaders["Authorization"] == Redactor.mask)
        #expect(!record.url.absoluteString.contains("abc"))
        #expect(record.responseBody?.data == Data(#"{"ok":true}"#.utf8))
    }

    @Test func capturesUploadBodies() async throws {
        URLSessionCapture.install(Self.capture)
        Self.store.clear()
        var request = URLRequest(url: URL(string: "https://example.com/upload")!)
        request.httpMethod = "POST"
        _ = await run(session(), request, upload: Data(#"{"name":"ali"}"#.utf8))
        Self.capture.flush()
        #expect(Self.store.records.first?.requestBody?.data == Data(#"{"name":"ali"}"#.utf8))
    }

    /// A session delegate that collects metrics keeps getting them: the inspector steps aside.
    @Test func leavesTheSessionDelegatesMetricsAlone() async throws {
        final class Delegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
            var calls = 0
            func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) { calls += 1 }
        }
        URLSessionCapture.install(Self.capture)
        let delegate = Delegate()
        _ = await run(session(delegate: delegate), URLRequest(url: URL(string: "https://example.com/a")!))
        try await Task.sleep(for: .milliseconds(200))
        #expect(delegate.calls == 1)
    }
}

// MARK: - Events (Phase 2)

@Suite struct EventCaptureTests {
    func capture() -> EventCapture {
        EventCapture(store: RecordStore(limits: .init(count: 100, bytes: 1_000_000), isPaused: false))
    }

    func record(_ capture: EventCapture) throws -> EventRecord {
        capture.flush()
        return try #require(capture.store.records.last)
    }

    @Test func recordsDeliveriesDroppedAndSuperProperties() throws {
        let capture = capture()
        capture.track(
            source: "TripAcceptedEvent",
            deliveries: [
                .init(destination: "CleverTap", name: "Trip Accepted", properties: ["trip_id": "7f3a", "driverid": "d_1"]),
                .init(destination: "Firebase", name: "trip_accepted", properties: ["trip_id": "7f3a", "eta": 240, "driverid": "d_1"]),
            ],
            superPropertyKeys: ["driverid"],
            dropped: [.init(destination: "LaunchDarkly", name: "trip_accepted", properties: nil)]
        )
        let event = try record(capture)
        #expect(event.name == "trip_accepted") // Firebase's name wins
        #expect(event.source == "TripAcceptedEvent")
        #expect(event.dropped == ["LaunchDarkly"])
        #expect(event.warnings.contains { $0.tag == "DROP" && $0.message.contains("LaunchDarkly") })
        let firebase = try #require(event.deliveries.first { $0.destination == "Firebase" })
        #expect(firebase.properties.map(\.key) == ["eta", "trip_id", "driverid"]) // own first, super last
        #expect(firebase.properties.last?.isSuper == true)
        #expect(firebase.properties.first?.value == .int(240))
    }

    @Test func eventDroppedEverywhereStillShows() throws {
        let capture = capture()
        capture.track(deliveries: [], dropped: [.init(destination: "Leanplum", name: "doc_uploaded", properties: nil)])
        #expect(try record(capture).name == "doc_uploaded")
    }

    @Test func typesValuesTheWaySDKsSeeThem() {
        #expect(EventRecord.Value(true) == .bool(true))
        #expect(EventRecord.Value(NSNumber(value: false)) == .bool(false))
        #expect(EventRecord.Value(NSNumber(value: 3)) == .int(3))
        #expect(EventRecord.Value(2.5) == .double(2.5))
        #expect(EventRecord.Value(Optional<Int>.some(4) as Any) == .int(4))
        #expect(EventRecord.Value(["a"]).typeName == "array")
        #expect(EventRecord.Value(Date()).typeName == "Date")
    }

    @Test func redactsKeysAndTextButChecksTheRealValues() throws {
        let capture = capture()
        capture.track(deliveries: [.init(destination: "Firebase", name: "login", properties: ["auth_token": "abc", "note": "call +213 555 000 111"])])
        let event = try record(capture)
        let properties = Dictionary(uniqueKeysWithValues: event.deliveries[0].properties.map { ($0.key, $0.value) })
        #expect(properties["auth_token"] == .string(Redactor.mask))
        #expect(properties["note"] != .string("call +213 555 000 111"))
        #expect(event.warnings.contains { $0.tag == "PII" && $0.message.contains("note") && $0.message.contains("phone") })
    }

    @Test func revealingShowsTheRealValues() throws {
        let capture = capture()
        capture.track(deliveries: [.init(destination: "Firebase", name: "login", properties: ["auth_token": "abc"])])
        let event = try record(capture).revealed()
        #expect(event.deliveries[0].properties[0].value == .string("abc"))
        #expect(!event.isRedacted)
    }

    @Test func flagsAPropertyChangingTypeButNotOptionalKeys() throws {
        let capture = capture()
        capture.track(deliveries: [.init(destination: "Firebase", name: "ride_requested", properties: ["fare": 612.5, "promo": "X"])])
        capture.track(deliveries: [.init(destination: "Firebase", name: "ride_requested", properties: ["fare": 600.0])])
        #expect(try record(capture).warnings.isEmpty) // "promo" missing is fine
        capture.track(deliveries: [.init(destination: "Firebase", name: "ride_requested", properties: ["fare": "612.5"])])
        let change = try #require(try record(capture).warnings.first { $0.tag == "TYPE" })
        #expect(change.message.contains("fare was sent as double") && change.message.contains("now as string"))
    }

    @Test func directSDKCallsAreRecordedWithoutEventChecks() throws {
        let capture = capture()
        capture.record(.identity, "identify", to: ["Firebase", "CleverTap"], properties: ["phone": "+213 555 000 111"])
        let record = try record(capture)
        #expect(record.kind == .identity)
        #expect(record.deliveries.map(\.destination) == ["Firebase", "CleverTap"])
        #expect(record.warnings.isEmpty) // a phone number is the point of an identity call
        #expect(record.deliveries[0].properties[0].value != .string("+213 555 000 111")) // still redacted
    }

    @Test func pausedStoreKeepsNothing() {
        let capture = EventCapture(store: RecordStore(limits: .init(count: 10, bytes: 10_000)))
        capture.track(deliveries: [.init(destination: "Firebase", name: "x", properties: nil)])
        capture.flush()
        #expect(capture.store.records.isEmpty)
    }

    @Test func reportsAsJSONAndMarkdown() throws {
        let capture = capture()
        capture.track(deliveries: [.init(destination: "Firebase", name: "app_opened", properties: ["count": 2])])
        let event = try record(capture)
        #expect(event.jsonText.contains(#""count" : 2"#))
        #expect(event.report(.markdown).contains("### Analytics event `app_opened`"))
        #expect(TextLog.jsonLines([event, event]).split(separator: "\n").count == 2)
    }
}

@Suite struct EventCheckTests {
    func warnings(_ destination: String, _ name: String, _ properties: [String: Any] = [:]) -> [EventRecord.Warning] {
        EventChecks.warnings(for: [EventRecord.Delivery(
            destination: destination, name: name,
            properties: properties.map { EventRecord.Property(key: $0.key, value: EventRecord.Value($0.value)) }
        )])
    }

    @Test(arguments: ["2fast", "has space", "firebase_x", "session_start", String(repeating: "a", count: 41)])
    func firebaseRejectsBadNames(_ name: String) {
        #expect(warnings("Firebase", name).contains { $0.tag == "FIR" })
    }

    @Test func firebaseAcceptsGoodEvents() {
        #expect(warnings("Firebase", "trip_accepted", ["trip_id": "7f3a", "eta": 2]).isEmpty)
    }

    @Test func firebaseLimits() {
        let many = Dictionary(uniqueKeysWithValues: (0..<26).map { ("p\($0)", $0 as Any) })
        #expect(warnings("Firebase", "e", many).contains { $0.message.contains("26 properties") })
        #expect(warnings("Firebase", "e", ["address": String(repeating: "x", count: 142)]).contains { $0.message.contains("142 characters") })
    }

    @Test func cleverTapLimits() {
        #expect(warnings("CleverTap", "Trip: accepted").contains { $0.tag == "CT" })
        #expect(warnings("CleverTap", "Trip Accepted", ["v": String(repeating: "x", count: 513)]).contains { $0.tag == "CT" })
        #expect(warnings("CleverTap", "Trip Accepted").isEmpty)
    }

    @Test func adjustWantsATokenNotAName() {
        #expect(warnings("Adjust", "trip_accepted").contains { $0.tag == "ADJ" })
        #expect(warnings("Adjust", "a1b2c3").isEmpty)
    }

    @Test func flagsUnsupportedTypes() {
        #expect(warnings("Firebase", "e", ["items": ["a"]]).contains { $0.tag == "TYPE" && $0.message.contains("array") })
        #expect(warnings("Firebase", "e", ["n": 1, "b": true, "s": "x", "d": 1.5]).filter { $0.tag == "TYPE" }.isEmpty)
    }

    // Personal-data heuristics.
    @Test(arguments: [
        ("accessToken", "credential"), ("authHeader", "credential"), ("sessionId", "credential"), ("clientSecret", "credential"),
        ("userPassword", "credential"), ("phoneNumber", "phone"), ("mobileNumber", "phone"), ("msisdn", "phone"),
        ("userEmail", "email"),
    ])
    func riskyKeys(_ key: String, _ risk: String) {
        #expect(EventChecks.risks(key: key, value: .string("v")).contains { $0.contains(risk) })
    }

    @Test(arguments: ["id", "transactionId", "rideId", "orderId", "screenName", "tabIndex", "isAuthenticated",
                      "userId", "deepLink", "apiURL", "reason", "errorCode"])
    func innocentKeys(_ key: String) {
        #expect(EventChecks.risks(key: key, value: .string("home")).isEmpty)
    }

    @Test func rawErrorsNeedASentence() {
        #expect(EventChecks.risks(key: "reason", value: .string("tokenNotExpired")).isEmpty)
        #expect(!EventChecks.risks(key: "errorDescription", value: .string("The operation couldn't be completed. (NSURLErrorDomain error -1001.)")).isEmpty)
    }

    @Test(arguments: [
        ("Bearer abc.def.ghi", "credential"), ("{ access_token: 'abc' }", "credential"), ("https://example.com/order/123", "URL"),
        ("www.example.com/promo", "URL"), ("Contact user@example.com for details", "email"), ("Reached at +213 555 000 111", "phone"),
        ("Call (555) 123-4567 anytime", "phone"), ("Call 555 123 4567", "phone"),
    ])
    func riskyValues(_ value: String, _ risk: String) {
        #expect(EventChecks.risks(key: "payload", value: .string(value)).contains { $0.contains(risk) })
    }

    @Test(arguments: ["2026-05-09", "2026-05-09T12:34:56Z", "4111-1111-1111-1111", "ride-12345-67890", "9876543210",
                      "ORD-2026-05-09-0001", "12345678901234567890"])
    func notPhones(_ value: String) {
        #expect(!EventChecks.looksLikePhone(value))
    }

    @Test func keyAndValueRiskIsOneWarning() {
        #expect(warnings("Firebase", "e", ["userEmail": "user@example.com"]).filter { $0.tag == "PII" }.count == 1)
    }
}

// MARK: - Direct SDK calls (swizzled)

@objc(InspectorFakeFirebase) final class InspectorFakeFirebase: NSObject {
    nonisolated(unsafe) static var received: [String] = []
    @objc(logEventWithName:parameters:) class func logEvent(withName name: String, parameters: [String: Any]?) {
        received.append(name)
    }
}

@objc(InspectorFakeSentry) final class InspectorFakeSentry: NSObject {
    nonisolated(unsafe) static var received: [String] = []
    @objc(captureError:withScope:) class func captureError(_ error: NSError, withScope scope: AnyObject) -> AnyObject {
        received.append(error.domain)
        return NSString(string: "sentry-id")
    }

    @objc(captureMessage:withScope:) class func captureMessage(_ message: NSString, withScope scope: AnyObject) -> AnyObject {
        received.append(message as String)
        return NSString(string: "sentry-id")
    }
}

@Suite(.serialized) struct DirectSDKCaptureTests {
    static let store = RecordStore<EventRecord>(limits: .init(count: 100, bytes: 1_000_000), isPaused: false)
    static let installed: Void = {
        DirectSDKCapture.capture = EventCapture(store: store)
        DirectSDKCapture.swizzleFirebase(className: "InspectorFakeFirebase")
        DirectSDKCapture.swizzleSentry(className: "InspectorFakeSentry")
    }()

    @Test func recordsDirectFirebaseEventsButNotTheSinksOwn() throws {
        _ = Self.installed
        Self.store.clear()
        let fake: AnyClass = InspectorFakeFirebase.self
        _ = (fake as AnyObject).perform(NSSelectorFromString("logEventWithName:parameters:"), with: "chat_opened", with: ["room": "r1"])
        DirectSDKCapture.whileForwarding {
            _ = (fake as AnyObject).perform(NSSelectorFromString("logEventWithName:parameters:"), with: "from_sink", with: nil)
        }
        DirectSDKCapture.capture?.flush()
        #expect(InspectorFakeFirebase.received.suffix(2) == ["chat_opened", "from_sink"]) // the SDK still gets both
        #expect(Self.store.records.map(\.name) == ["chat_opened"])
        #expect(Self.store.records.first?.deliveries.first?.destination == "Firebase")
    }

    @Test func recordsSentryCapturesAndKeepsTheReturnValue() throws {
        _ = Self.installed
        Self.store.clear()
        let fake: AnyObject = InspectorFakeSentry.self
        let id = fake.perform(NSSelectorFromString("captureError:withScope:"), with: NSError(domain: "Marketplace.API", code: 422), with: NSObject())
        _ = fake.perform(NSSelectorFromString("captureMessage:withScope:"), with: "cart desynced", with: NSObject())
        DirectSDKCapture.capture?.flush()
        #expect(id?.takeUnretainedValue() as? String == "sentry-id")
        #expect(Self.store.records.map(\.name) == ["Marketplace.API (422)", "cart desynced"])
        #expect(Self.store.records.map(\.kind) == [.error, .log])
    }
}
