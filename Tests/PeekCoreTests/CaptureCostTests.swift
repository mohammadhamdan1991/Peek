#if !PEEK_DISABLED
import Foundation
import Testing
import PeekCore

/// What capture adds to each request on the networking callback thread: started + finished + timing,
/// with default redaction, for a realistic API payload (1 KB request, ~20 KB response).
/// Prints the per-request cost; fails only on a gross regression.
@Suite struct CaptureCostTests {
    @Test func perRequestCaptureCost() {
        let request = Data(#"{"lat":36.7538,"lng":3.0588,"heading":212,"speed":11.4,"accuracy":5,"token":"abc","phone":"+213 555 12 34 56"}"#.utf8)
        let trip = #"{"id":"7f3a","status":"DRIVER_ARRIVED","pickup":{"lat":36.75,"lng":3.05,"address":"Rue Didouche Mourad"},"fare":640,"rider":{"name":"A","phone":"0555123456"}}"#
        let response = Data(("{\"trips\":[" + Array(repeating: trip, count: 100).joined(separator: ",") + "]}").utf8)
        let headers = ["Authorization": "Bearer x", "Content-Type": "application/json", "Accept-Language": "fr-DZ"]
        let url = URL(string: "https://api.staging.example.com/v2/driver/trips?page=1&access_token=abc")!
        let capture = HTTPCapture(store: RecordStore(limits: .init(count: 1_000, bytes: 25 * 1_048_576), isPaused: false))
        let t0 = Date()
        let timing = HTTPTiming(domainLookup: nil, connect: nil, secureConnection: nil,
                                request: DateInterval(start: t0, duration: 0.001), response: DateInterval(start: t0.addingTimeInterval(0.2), duration: 0.01),
                                networkProtocol: "h2", isReusedConnection: true)

        let iterations = 500
        let clock = ContinuousClock()
        var onCaller = Duration.zero
        let total = clock.measure {
            for _ in 0..<iterations {
                let id = UUID()
                onCaller += clock.measure {
                    capture.started(id: id, correlationID: id, startedAt: t0, method: "POST", url: url, headers: headers, body: request)
                    capture.timing(id: id, timing)
                    capture.finished(id: id, correlationID: id, method: "POST", url: url, statusCode: 200,
                                     headers: headers, body: response, error: nil, duration: 0.21)
                }
            }
            capture.flush()
        }
        let callerPerRequest = onCaller / iterations
        let backgroundPerRequest = total / iterations
        print("CAPTURE COST: networking thread \(callerPerRequest) per request; background \(backgroundPerRequest) per request (response \(response.count / 1024) KB)")
        #expect(capture.store.records.count == iterations)
        #expect(callerPerRequest < .microseconds(200))
        #expect(backgroundPerRequest < .milliseconds(10))
    }
}
#endif
