#if !PEEK_DISABLED
import Foundation
import ObjectiveC

/// Captures calls made straight to an SDK from code the app can't change: third-party or in-house packages that
/// log Firebase events or report to Sentry themselves. Swizzles the SDKs' Objective-C entry
/// points, found by class name, so the package needs neither SDK; an SDK that isn't linked is skipped.
///
/// The app's own analytics sink already reports its events: wrap its forwarding in `whileForwarding` so its
/// Firebase calls aren't recorded twice.
public enum DirectSDKCapture {
    // Written once in `install`, before the swizzles make it reachable; read-only afterwards.
    nonisolated(unsafe) static var capture: EventCapture?
    private static let lock = NSLock()
    private static let forwardingKey = "Peek.DirectSDKCapture.forwarding"

    public static func install(_ capture: EventCapture) {
        lock.lock()
        defer { lock.unlock() }
        guard self.capture == nil else { return }
        self.capture = capture
        swizzleFirebase(className: "FIRAnalytics")
        swizzleSentry(className: "SentrySDKInternal")
    }

    /// Runs `body` with direct capture off on this thread: for the app's own sink, which reports its events itself.
    public static func whileForwarding<T>(_ body: () throws -> T) rethrows -> T {
        let thread = Thread.current.threadDictionary
        let depth = thread[forwardingKey] as? Int ?? 0
        thread[forwardingKey] = depth + 1
        defer { thread[forwardingKey] = depth }
        return try body()
    }

    static var isForwarding: Bool { (Thread.current.threadDictionary[forwardingKey] as? Int ?? 0) > 0 }

    // MARK: Firebase: + [FIRAnalytics logEventWithName:parameters:]

    static func swizzleFirebase(className: String) {
        typealias Original = @convention(c) (AnyObject, Selector, NSString, NSDictionary?) -> Void
        let selector = NSSelectorFromString("logEventWithName:parameters:")
        replaceClassMethod(className, selector, as: Original.self) { original in
            let block: @convention(block) (AnyObject, NSString, NSDictionary?) -> Void = { receiver, name, parameters in
                if !isForwarding {
                    capture?.track(
                        source: "Direct call (not via the app's analytics sink)",
                        deliveries: [.init(destination: "Firebase", name: name as String, properties: parameters as? [String: Any])]
                    )
                }
                original(receiver, selector, name, parameters)
            }
            return block
        }
    }

    // MARK: Sentry: + [SentrySDKInternal capture…:withScope:], where every capture call ends up

    static func swizzleSentry(className: String) {
        // Returned objects pass straight through, unretained, so ownership is the SDK's as before.
        typealias Original = @convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> Unmanaged<AnyObject>?
        let captures: [(selector: String, kind: EventRecord.Kind, describe: (AnyObject) -> (String, [String: Any]))] = [
            ("captureError:withScope:", .error, { object in
                let error = object as? NSError
                return ("\(error?.domain ?? "Error") (\(error?.code ?? 0))", error?.userInfo ?? [:])
            }),
            ("captureException:withScope:", .error, { object in
                let exception = object as? NSException
                return (exception?.name.rawValue ?? "Exception", ["reason": exception?.reason ?? ""])
            }),
            ("captureMessage:withScope:", .log, { object in ("\(object)", [:]) }),
            ("captureEvent:withScope:", .error, { object in (text(object, "message.formatted") ?? "Event", [:]) }),
        ]
        for entry in captures {
            let selector = NSSelectorFromString(entry.selector)
            replaceClassMethod(className, selector, as: Original.self) { original in
                let block: @convention(block) (AnyObject, AnyObject, AnyObject) -> Unmanaged<AnyObject>? = { receiver, value, scope in
                    let (name, properties) = entry.describe(value)
                    capture?.record(entry.kind, name, to: ["Sentry"], properties: properties, source: "Direct call (Sentry)")
                    return original(receiver, selector, value, scope)
                }
                return block
            }
        }
    }

    /// A key path read only when every step exists: KVC on a missing key raises.
    private static func text(_ object: AnyObject, _ keyPath: String) -> String? {
        var current: AnyObject? = object
        for key in keyPath.split(separator: ".") {
            guard let next = current, next.responds(to: NSSelectorFromString(String(key))) else { return nil }
            current = next.value(forKey: String(key)) as AnyObject?
        }
        return current as? String
    }

    /// Replaces a class method, handing `makeBlock` the original implementation to call through to.
    private static func replaceClassMethod<Original>(
        _ className: String,
        _ selector: Selector,
        as _: Original.Type,
        makeBlock: (Original) -> Any
    ) {
        guard let cls = NSClassFromString(className), let metaclass = object_getClass(cls),
              let method = class_getClassMethod(cls, selector) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let replacement = imp_implementationWithBlock(makeBlock(original))
        class_replaceMethod(metaclass, selector, replacement, method_getTypeEncoding(method))
    }
}
#endif
