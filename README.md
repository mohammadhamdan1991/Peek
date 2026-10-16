# Peek

An in-app debugging panel for iOS: every network request, socket message and analytics event your app sends,
in a floating panel you open on the device. Built for QA and developers who need to see *what the app actually
did* without attaching a proxy or a debugger.

- **Network:** requests and responses with headers, bodies (JSON tree, images, text), timing waterfall, retries
  grouped, search (`status:5xx host:api method:post`), cURL / HAR / Markdown export.
- **Sockets:** messages and connection changes, mixed into the same timeline.
- **Events:** every analytics event per destination (Firebase, Amplitude, …), with checks for SDK limits
  (Firebase name and parameter rules, CleverTap limits, Adjust tokens), wrong types and personal data. Plus
  identity calls, logs and errors.
- **Redaction:** tokens, passwords, cookies, emails and phone numbers are masked by default; one switch reveals
  the real values (kept in memory only) when you need a working cURL.
- **Zero-setup capture** for `URLSession` (completion-handler tasks), Firebase `logEvent` and Sentry, including calls
  made inside third-party packages.

Requires iOS 16.6+. No dependencies.

## Install

Swift Package Manager:

```swift
.package(url: "https://github.com/mohammadhamdan1991/Peek.git", from: "0.1.0")
```

Add the `Peek` product to your app target.

## Quick start

```swift
import Peek

@main
struct MyApp: App {
    init() {
        #if DEBUG
        Inspector.start(InspectorConfiguration(capturesAllURLSessionTraffic: true))
        #endif
    }
    var body: some Scene { WindowGroup { ContentView() } }
}
```

A floating button appears on every window. Tap it to open the panel; long-press for quick actions (copy last cURL,
pause, clear, hide).

## Keep it out of production

Peek is a debugging tool: don't ship it to your users. Pick one:

1. **Simple:** call `Inspector.start` only inside `#if DEBUG` (or your own flag). Peek is linked but never starts,
   and `Inspector.start` also refuses to run when `isProductionEnvironment` is true, for an unlisted bundle id
   (`allowedBundleIdentifiers`) or for an App Store install.
2. **Strict:** add `PEEK_DISABLED` to *Active Compilation Conditions* for your release configurations. Every Peek
   source file compiles to nothing, so the binary contains none of it. This needs the flag to reach the package
   targets (Tuist `PackageSettings`, or compiling the sources as your own targets). Then run
   [`Scripts/verify_no_peek.sh`](Scripts/verify_no_peek.sh) on every release `.ipa` in CI: it fails the build if any
   Peek code is inside.

## Feeding it data

| What | How |
|---|---|
| `URLSession` traffic | `capturesAllURLSessionTraffic: true` (swizzles completion-handler `dataTask` / `uploadTask`) |
| Your own networking layer | call `Inspector.capture.started(...)`, `.finished(...)`, `.timing(...)` from its logger: retries, decoding errors and modules show up |
| Sockets | `Inspector.socketCapture.record(...)` from your socket client's event handler |
| Analytics | `Inspector.eventCapture.track(source:deliveries:...)` from your analytics layer, one delivery per destination |
| Identity, logs, errors | `Inspector.eventCapture.record(.identity / .log / .error, name, to: [...])` |
| Firebase / Sentry calls you don't own | `DirectSDKCapture.install(Inspector.eventCapture)`; wrap your own analytics forwarding in `DirectSDKCapture.whileForwarding { … }` |

## Example

```bash
cd Example && tuist install && tuist generate
```

## License

MIT
