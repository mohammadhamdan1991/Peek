#if !PEEK_DISABLED
import Foundation
import ObjectiveC

/// Captures tasks that report through a session delegate instead of a completion handler: Alamofire, and any
/// app that makes its own `URLSession(configuration:delegate:delegateQueue:)`.
///
/// How: when a session is created with a delegate, the delegate's class gets three of its callbacks wrapped:
/// `didReceive data` (to keep a copy of the body), `didFinishCollecting metrics` (timing) and
/// `didCompleteWithError` (record the request). Each wrapper calls the original first-hand, so the delegate keeps
/// doing everything it did, SSL pinning and retries included, and the request is sent once, on the app's own session.
/// A URLProtocol (what DebugSwift uses) would re-send it on a session of its own, outside the app's delegate.
///
/// Requests appear when they finish. Sessions created before `install` aren't seen. Sessions whose delegate is a
/// URLProtocol are skipped: those are another debugging tool re-sending the app's request.
enum URLSessionDelegateCapture {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var hookedClasses: Set<ObjectIdentifier> = []
    nonisolated(unsafe) private static var bodyKey: UInt8 = 0
    nonisolated(unsafe) private static var metricsKey: UInt8 = 0
    nonisolated(unsafe) static var capturedKey: UInt8 = 0

    static func install() {
        typealias Factory = @convention(c) (AnyObject, Selector, URLSessionConfiguration, AnyObject?, OperationQueue?) -> AnyObject
        let selector = NSSelectorFromString("sessionWithConfiguration:delegate:delegateQueue:")
        guard let cls = NSClassFromString("NSURLSession"), let metaclass = object_getClass(cls),
              let method = class_getClassMethod(cls, selector) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: Factory.self)
        let block: @convention(block) (AnyObject, URLSessionConfiguration, AnyObject?, OperationQueue?) -> AnyObject = { receiver, configuration, delegate, queue in
            // A URLProtocol as delegate means a re-send (DebugSwift, netfox, Wormholy forward each request on a
            // session of their own): the app's own task already records it, so this copy would show twice.
            if let delegate, shouldObserve(delegate) { hook(type(of: delegate)) }
            return original(receiver, selector, configuration, delegate, queue)
        }
        class_replaceMethod(metaclass, selector, imp_implementationWithBlock(block), method_getTypeEncoding(method))
    }

    static func shouldObserve(_ delegate: AnyObject) -> Bool { !(delegate is URLProtocol) }

    /// Marks a task already captured another way (completion handler, async API), so it isn't recorded twice.
    static func markCaptured(_ task: URLSessionTask) {
        objc_setAssociatedObject(task, &capturedKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private static func hook(_ delegateClass: AnyClass) {
        lock.lock()
        defer { lock.unlock() }
        guard hookedClasses.insert(ObjectIdentifier(delegateClass)).inserted else { return }

        // Body: only wrapped where the delegate already handles data. Adding it would take the body away from a
        // delegate that relies on the system collecting it.
        typealias DataFn = @convention(c) (AnyObject, Selector, URLSession, URLSessionDataTask, Data) -> Void
        let dataSelector = #selector(URLSessionDataDelegate.urlSession(_:dataTask:didReceive:) as (URLSessionDataDelegate) -> ((URLSession, URLSessionDataTask, Data) -> Void)?)
        wrap(delegateClass, dataSelector, as: DataFn.self, addIfMissing: false) { original in
            let block: @convention(block) (AnyObject, URLSession, URLSessionDataTask, Data) -> Void = { delegate, session, task, data in
                if !isCaptured(task) { body(of: task).append(data) }
                original?(delegate, dataSelector, session, task, data)
            }
            return block
        }

        typealias MetricsFn = @convention(c) (AnyObject, Selector, URLSession, URLSessionTask, URLSessionTaskMetrics) -> Void
        let metricsSelector = #selector(URLSessionTaskDelegate.urlSession(_:task:didFinishCollecting:))
        wrap(delegateClass, metricsSelector, as: MetricsFn.self, addIfMissing: true) { original in
            let block: @convention(block) (AnyObject, URLSession, URLSessionTask, URLSessionTaskMetrics) -> Void = { delegate, session, task, metrics in
                objc_setAssociatedObject(task, &metricsKey, metrics, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                original?(delegate, metricsSelector, session, task, metrics)
            }
            return block
        }

        typealias CompleteFn = @convention(c) (AnyObject, Selector, URLSession, URLSessionTask, Error?) -> Void
        let completeSelector = #selector(URLSessionTaskDelegate.urlSession(_:task:didCompleteWithError:))
        wrap(delegateClass, completeSelector, as: CompleteFn.self, addIfMissing: true) { original in
            let block: @convention(block) (AnyObject, URLSession, URLSessionTask, Error?) -> Void = { delegate, session, task, error in
                record(task, session: session, error: error)
                original?(delegate, completeSelector, session, task, error)
            }
            return block
        }
    }

    private static func isCaptured(_ task: URLSessionTask) -> Bool {
        objc_getAssociatedObject(task, &capturedKey) as? Bool == true
    }

    private static func body(of task: URLSessionTask) -> NSMutableData {
        if let data = objc_getAssociatedObject(task, &bodyKey) as? NSMutableData { return data }
        let data = NSMutableData()
        objc_setAssociatedObject(task, &bodyKey, data, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return data
    }

    private static func record(_ task: URLSessionTask, session: URLSession, error: Error?) {
        // Also covers a subclass calling `super`: the first wrapper to run records, the next one skips.
        guard let capture = URLSessionCapture.capture, !isCaptured(task), !capture.store.isPaused,
              let request = task.originalRequest ?? task.currentRequest, let url = request.url,
              url.scheme?.hasPrefix("http") == true else { return }
        markCaptured(task)
        let metrics = objc_getAssociatedObject(task, &metricsKey) as? URLSessionTaskMetrics
        let id = UUID()
        let method = request.httpMethod ?? "GET"
        var headers = (task.currentRequest ?? request).allHTTPHeaderFields ?? [:]
        for case let (name as String, value as String) in session.configuration.httpAdditionalHeaders ?? [:]
        where headers[name] == nil {
            headers[name] = value
        }
        let http = task.response as? HTTPURLResponse
        let data = objc_getAssociatedObject(task, &bodyKey) as? NSMutableData
        capture.started(id: id, correlationID: nil, startedAt: metrics?.taskInterval.start ?? Date(), method: method,
                        url: url, headers: headers, body: request.httpBody)
        capture.finished(
            id: id, correlationID: nil, method: method, url: url,
            statusCode: http?.statusCode,
            headers: http?.allHeaderFields.reduce(into: [String: String]()) { $0["\($1.key)"] = "\($1.value)" },
            body: data.map { Data($0) },
            error: error.map { "\(($0 as NSError).domain)(\(($0 as NSError).code)): \($0.localizedDescription)" },
            duration: metrics?.taskInterval.duration
        )
        if let metrics { capture.timing(id: id, URLSessionCapture.timing(from: metrics)) }
    }

    /// Wraps `selector` on `cls`, handing `makeBlock` the implementation it replaces (nil if there was none).
    private static func wrap<Fn>(_ cls: AnyClass, _ selector: Selector, as _: Fn.Type, addIfMissing: Bool,
                                 makeBlock: (Fn?) -> Any) {
        let method = class_getInstanceMethod(cls, selector)
        guard method != nil || addIfMissing else { return }
        let original = method.map { unsafeBitCast(method_getImplementation($0), to: Fn.self) }
        let replacement = imp_implementationWithBlock(makeBlock(original))
        let types = method.flatMap { method_getTypeEncoding($0) }
            ?? protocol_getMethodDescription(URLSessionTaskDelegate.self, selector, false, true).types.map { UnsafePointer($0) }
        // Adds the method to `cls` itself when it was only inherited, so a superclass stays untouched.
        if !class_addMethod(cls, selector, replacement, types), let method {
            method_setImplementation(method, replacement)
        }
    }
}
#endif
