#if !PEEK_DISABLED
import Foundation
import ObjectiveC

/// Captures `URLSession` requests in the app, with no change to the networking code: completion-handler tasks
/// and the `async` APIs (`data(for:)`, `data(from:)`, `upload(for:from:)`, `upload(for:fromFile:)`).
///
/// How: wraps the completion handler at the point each task is created, and sets a per-task delegate for timing.
/// Requests are sent exactly as before (same session, same delegate, same TLS handling), unlike a URLProtocol,
/// which re-sends them on its own session.
/// - Completion-handler APIs: swizzles `dataTask(with:completionHandler:)` and `uploadTask(with:from:completionHandler:)`.
/// - `async` APIs are Swift-only, but Foundation implements them on private `NSURLSession` methods that take a
///   completion handler (`_dataTaskWithRequest:delegate:completionHandler:` and siblings). Those are hooked by
///   name; if a future OS renames them, async capture is skipped and nothing else changes.
///
/// Not seen: delegate-only tasks (no completion handler), `bytes(for:)` streams, retries grouped as one call,
/// decoding errors. Don't combine with your own `Inspector.capture` feed: its requests would show twice.
public enum URLSessionCapture {
    // Written once in `install`, before the swizzle makes it reachable; read-only afterwards.
    nonisolated(unsafe) static var capture: HTTPCapture?
    private static let lock = NSLock()

    public static func install(_ capture: HTTPCapture) {
        lock.lock()
        defer { lock.unlock() }
        guard self.capture == nil else { return }
        self.capture = capture
        // Sessions are a private subclass (`__NSURLSessionLocal`) that may override these, so swizzle the class
        // instances actually have.
        let probe = URLSession(configuration: .ephemeral)
        defer { probe.invalidateAndCancel() }
        guard let sessionClass = object_getClass(probe) else { return }
        swizzle(sessionClass, #selector(URLSession.dataTask(with:completionHandler:) as (URLSession) -> (URLRequest, @escaping @Sendable (Data?, URLResponse?, Error?) -> Void) -> URLSessionDataTask),
                #selector(URLSession.yi_dataTask(with:completionHandler:)))
        swizzle(sessionClass, #selector(URLSession.uploadTask(with:from:completionHandler:) as (URLSession) -> (URLRequest, Data?, @escaping @Sendable (Data?, URLResponse?, Error?) -> Void) -> URLSessionUploadTask),
                #selector(URLSession.yi_uploadTask(with:from:completionHandler:)))
        hookAsyncEntryPoints()
    }

    // MARK: async APIs

    typealias ObjCCompletion = @convention(block) @Sendable (Data?, URLResponse?, Error?) -> Void
    /// Set while a public completion-handler method runs, in case it creates its task through the private one:
    /// the request is then already being captured and mustn't show twice.
    private static let reentryKey = "Peek.URLSessionCapture.inPublicCall"
    static var isInPublicCall: Bool { Thread.current.threadDictionary[reentryKey] as? Bool ?? false }
    static func publicCall<T>(_ body: () -> T) -> T {
        Thread.current.threadDictionary[reentryKey] = true
        defer { Thread.current.threadDictionary[reentryKey] = nil }
        return body()
    }

    private static func hookAsyncEntryPoints() {
        // (request or URL, delegate, completion)
        for name in ["_dataTaskWithRequest:delegate:completionHandler:", "_dataTaskWithURL:delegate:completionHandler:"] {
            let selector = NSSelectorFromString(name)
            typealias Fn = @convention(c) (AnyObject, Selector, AnyObject, AnyObject?, ObjCCompletion?) -> AnyObject
            replaceMethod(selector, as: Fn.self) { original in
                let block: @convention(block) (AnyObject, AnyObject, AnyObject?, ObjCCompletion?) -> AnyObject = { session, target, delegate, done in
                    let (completion, finish) = wrapAsync(session, target, body: nil, done)
                    return finish(original(session, selector, target, delegate, completion))
                }
                return block
            }
        }
        // (request, data or file URL, delegate, completion)
        for (name, carriesData) in [("_uploadTaskWithRequest:fromData:delegate:completionHandler:", true),
                                    ("_uploadTaskWithRequest:fromFile:delegate:completionHandler:", false)] {
            let selector = NSSelectorFromString(name)
            typealias Fn = @convention(c) (AnyObject, Selector, AnyObject, AnyObject?, AnyObject?, ObjCCompletion?) -> AnyObject
            replaceMethod(selector, as: Fn.self) { original in
                let block: @convention(block) (AnyObject, AnyObject, AnyObject?, AnyObject?, ObjCCompletion?) -> AnyObject = { session, request, source, delegate, done in
                    let body = carriesData ? source as? Data : nil
                    let (completion, finish) = wrapAsync(session, request, body: body, done)
                    return finish(original(session, selector, request, source, delegate, completion))
                }
                return block
            }
        }
    }

    /// The completion to pass on (wrapped when capturing), and what to do with the created task (start timing).
    private static func wrapAsync(
        _ sessionObject: AnyObject, _ target: AnyObject, body: Data?, _ done: ObjCCompletion?
    ) -> (ObjCCompletion?, (AnyObject) -> AnyObject) {
        let request: URLRequest? = switch target {
        case let request as URLRequest: request
        case let url as URL: URLRequest(url: url)
        default: nil
        }
        guard !isInPublicCall, let session = sessionObject as? URLSession, let request, let done,
              let (id, wrapped) = begin(session, request, body: body, { data, response, error in done(data, response, error) })
        else { return (done, { $0 }) }
        let completion: ObjCCompletion = { data, response, error in wrapped(data, response, error) }
        return (completion, { task in
            if let task = task as? URLSessionTask { observeMetrics(task, session: session, id: id) }
            return task
        })
    }

    /// Replaces an `NSURLSession` instance method, handing `makeBlock` the original implementation to call through to.
    private static func replaceMethod<Original>(_ selector: Selector, as _: Original.Type, makeBlock: (Original) -> Any) {
        guard let cls = NSClassFromString("NSURLSession"), let method = class_getInstanceMethod(cls, selector) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        method_setImplementation(method, imp_implementationWithBlock(makeBlock(original)))
    }

    private static func swizzle(_ cls: AnyClass, _ original: Selector, _ replacement: Selector) {
        guard let originalMethod = class_getInstanceMethod(cls, original),
              let replacementMethod = class_getInstanceMethod(URLSession.self, replacement) else { return }
        // If `cls` only inherits the original, give it its own copy first so the base class stays untouched.
        if class_addMethod(cls, original, method_getImplementation(replacementMethod), method_getTypeEncoding(replacementMethod)) {
            class_replaceMethod(cls, replacement, method_getImplementation(originalMethod), method_getTypeEncoding(originalMethod))
        } else {
            method_exchangeImplementations(originalMethod, replacementMethod)
        }
    }

    typealias Completion = @Sendable (Data?, URLResponse?, Error?) -> Void

    /// Logs the start and wraps `completion` to log the end. Nil when there's nothing to wrap.
    static func begin(_ session: URLSession, _ request: URLRequest, body: Data?, _ completion: Completion?) -> (UUID, Completion)? {
        guard let capture, let completion, let url = request.url, !capture.store.isPaused else { return nil }
        let id = UUID()
        let start = Date()
        var headers = request.allHTTPHeaderFields ?? [:]
        for case let (name as String, value as String) in session.configuration.httpAdditionalHeaders ?? [:]
        where request.value(forHTTPHeaderField: name) == nil {
            headers[name] = value // what goes on the wire
        }
        let method = request.httpMethod ?? "GET"
        capture.started(id: id, correlationID: nil, startedAt: start, method: method, url: url,
                        headers: headers, body: body ?? request.httpBody)
        return (id, { data, response, error in
            let http = response as? HTTPURLResponse
            capture.finished(
                id: id, correlationID: nil, method: method, url: url,
                statusCode: http?.statusCode,
                headers: http?.allHeaderFields.reduce(into: [String: String]()) { $0["\($1.key)"] = "\($1.value)" },
                body: data,
                error: error.map { "\(($0 as NSError).domain)(\(($0 as NSError).code)): \($0.localizedDescription)" },
                duration: Date().timeIntervalSince(start)
            )
            completion(data, response, error)
        })
    }

    /// Timing via the task's own delegate, so the session's delegate is left alone. Skipped when the task
    /// already has one, or the session delegate collects metrics itself (it would stop getting them).
    static func observeMetrics(_ task: URLSessionTask, session: URLSession, id: UUID) {
        guard let capture, task.delegate == nil,
              (session.delegate as? NSObject)?.responds(to: #selector(URLSessionTaskDelegate.urlSession(_:task:didFinishCollecting:))) != true
        else { return }
        task.delegate = MetricsDelegate(id: id, capture: capture)
    }

    private final class MetricsDelegate: NSObject, URLSessionTaskDelegate {
        let id: UUID
        let capture: HTTPCapture
        init(id: UUID, capture: HTTPCapture) {
            self.id = id
            self.capture = capture
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            guard let transaction = metrics.transactionMetrics.last else { return }
            func interval(_ start: Date?, _ end: Date?) -> DateInterval? {
                guard let start, let end, end >= start else { return nil }
                return DateInterval(start: start, end: end)
            }
            capture.timing(id: id, HTTPTiming(
                domainLookup: interval(transaction.domainLookupStartDate, transaction.domainLookupEndDate),
                connect: interval(transaction.connectStartDate, transaction.connectEndDate),
                secureConnection: interval(transaction.secureConnectionStartDate, transaction.secureConnectionEndDate),
                request: interval(transaction.requestStartDate, transaction.requestEndDate),
                response: interval(transaction.responseStartDate, transaction.responseEndDate),
                networkProtocol: transaction.networkProtocolName,
                isReusedConnection: transaction.isReusedConnection
            ))
        }
    }
}

extension URLSession {
    // After the swizzle these names point at the original implementations.
    @objc dynamic func yi_dataTask(with request: URLRequest, completionHandler: URLSessionCapture.Completion?) -> URLSessionDataTask {
        guard let (id, wrapped) = URLSessionCapture.begin(self, request, body: nil, completionHandler) else {
            return yi_dataTask(with: request, completionHandler: completionHandler)
        }
        let task = URLSessionCapture.publicCall { yi_dataTask(with: request, completionHandler: wrapped) }
        URLSessionCapture.observeMetrics(task, session: self, id: id)
        return task
    }

    @objc dynamic func yi_uploadTask(with request: URLRequest, from body: Data?, completionHandler: URLSessionCapture.Completion?) -> URLSessionUploadTask {
        guard let (id, wrapped) = URLSessionCapture.begin(self, request, body: body, completionHandler) else {
            return yi_uploadTask(with: request, from: body, completionHandler: completionHandler)
        }
        let task = URLSessionCapture.publicCall { yi_uploadTask(with: request, from: body, completionHandler: wrapped) }
        URLSessionCapture.observeMetrics(task, session: self, id: id)
        return task
    }
}
#endif
