import Foundation

@main
struct ShareTransportSmoke {
    static func main() async {
        guard CommandLine.arguments.count == 2,
              let endpoint = URL(string: CommandLine.arguments[1]),
              let sessionID = ShareSessionID(rawValue: "123456") else {
            fputs("usage: share_transport_smoke <http://127.0.0.1:port>\n", stderr)
            exit(2)
        }

        do {
            _ = try await ShareClient.claim(sessionID: sessionID, endpoint: endpoint)
            fputs("share_transport_smoke: oversized response was accepted\n", stderr)
            exit(1)
        } catch ShareClient.ShareError.invalidResponse {
            print("share_transport_smoke: oversized response rejected")
        } catch {
            fputs("share_transport_smoke: unexpected error: \(error)\n", stderr)
            exit(1)
        }
    }
}
