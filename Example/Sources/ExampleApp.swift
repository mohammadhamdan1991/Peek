import Peek
import SwiftUI

@main
struct ExampleApp: App {
    init() {
        // Plain URLSession apps need no networking hooks: Peek captures every completion-handler task.
        Inspector.start(InspectorConfiguration(environmentTag: "DEMO", capturesAllURLSessionTraffic: true))
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    var body: some View {
        NavigationStack {
            Form {
                Section("Requests (httpbin.org)") {
                    Button("GET 200") { send("https://httpbin.org/get?page=1") }
                    Button("POST with a token and a password") {
                        send("https://httpbin.org/post", method: "POST",
                             body: #"{"email":"jane@example.com","password":"hunter2"}"#,
                             headers: ["Authorization": "Bearer demo-token-123"])
                    }
                    Button("GET 404") { send("https://httpbin.org/status/404") }
                    Button("GET 503") { send("https://httpbin.org/status/503") }
                    Button("async GET (try await data(for:))") {
                        Task { _ = try? await URLSession.shared.data(for: URLRequest(url: URL(string: "https://httpbin.org/uuid")!)) }
                    }
                }

                Section("Analytics (what your analytics layer reports)") {
                    Button("checkout_completed (to Firebase and Amplitude)") {
                        Inspector.eventCapture.track(
                            source: "CheckoutEvent",
                            deliveries: ["Firebase", "Amplitude"].map {
                                .init(destination: $0, name: "checkout_completed", properties: [
                                    "order_id": "A-1042", "total": 39.9, "items": 3, "coupon": "SPRING",
                                    "shipping_address": String(repeating: "221B Baker Street, London, ", count: 5),
                                ])
                            }
                        )
                    }
                    Button("Screen view: Cart") {
                        Inspector.eventCapture.track(kind: .screenView, deliveries: [
                            .init(destination: "Firebase", name: "cart", properties: ["items": 3]),
                        ])
                    }
                    Button("Identity: user signed in") {
                        Inspector.eventCapture.record(.identity, "setUserID", to: ["Firebase", "Amplitude"],
                                                      properties: ["user_id": "u_123", "email": "jane@example.com"])
                    }
                }

                Section("Inspector") {
                    Button("Open panel") { Inspector.show() }
                    Button("Show button again") { Inspector.showButton() }
                }
            }
            .navigationTitle("Peek demo")
        }
    }

    private func send(_ url: String, method: String = "GET", body: String? = nil, headers: [String: String] = [:]) {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.httpBody = body.map { Data($0.utf8) }
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }
}
