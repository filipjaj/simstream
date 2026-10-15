import Foundation

/// A SimStream share link: `https://<tunnel>/<token>/`. Everything the Mac serves lives under the token.
struct StreamLink: Hashable, Codable, Sendable {
  let pageURL: URL
  let webSocketURL: URL

  var host: String { pageURL.host() ?? "" }

  /// Accepts what people actually paste: with or without scheme or trailing slash, a deeper path
  /// under the token (`/ws`, `/health`), or `simstream://` from a tapped link.
  init?(_ raw: String) {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if !text.contains("://") { text = "https://" + text }
    guard var components = URLComponents(string: text), let host = components.host, !host.isEmpty else { return nil }

    switch components.scheme?.lowercased() {
    case "https", "http":
      break
    case "simstream":
      components.scheme = Self.isLocal(host) ? "http" : "https"
    default:
      return nil
    }
    guard let token = components.path.split(separator: "/").first, !token.isEmpty else { return nil }

    components.path = "/\(token)/"
    components.query = nil
    components.fragment = nil
    guard let page = components.url else { return nil }

    components.scheme = components.scheme == "https" ? "wss" : "ws"
    components.path = "/\(token)/ws"
    guard let socket = components.url else { return nil }

    pageURL = page
    webSocketURL = socket
  }

  private static func isLocal(_ host: String) -> Bool {
    host == "localhost" || host.hasSuffix(".local") || host.allSatisfy { $0.isNumber || $0 == "." || $0 == ":" }
  }
}
