import Foundation

/// How a container should look in a list: a glyph and a colour derived from its image.
///
/// Rows read far faster when Postgres is always the same blue elephant-ish tile and Redis the
/// same red one. Well-known images get a hand-picked symbol and hue; everything else gets a
/// monogram and a colour derived from its own name, so it's still stable and distinguishable
/// without pretending to recognise it.
public struct ImageAppearance: Sendable, Equatable {
    /// An SF Symbol name, when one genuinely fits the software.
    public let symbol: String?
    /// One or two letters, used when there's no symbol.
    public let monogram: String
    /// 0…1 hue for the tile's colour.
    public let hue: Double

    public init(symbol: String?, monogram: String, hue: Double) {
        self.symbol = symbol
        self.monogram = monogram
        self.hue = hue
    }

    /// A curated set: the images people actually run, with colours close to their own branding.
    private static let known: [(match: String, symbol: String?, hue: Double)] = [
        ("postgres", "cylinder.split.1x2", 0.58),
        ("mysql", "cylinder.split.1x2", 0.09),
        ("mariadb", "cylinder.split.1x2", 0.07),
        ("mongo", "leaf", 0.30),
        ("redis", "bolt.horizontal", 0.01),
        ("valkey", "bolt.horizontal", 0.55),
        ("nginx", "arrow.triangle.branch", 0.33),
        ("traefik", "arrow.triangle.branch", 0.50),
        ("caddy", "arrow.triangle.branch", 0.45),
        ("httpd", "arrow.triangle.branch", 0.02),
        ("minio", "shippingbox", 0.98),
        ("rabbitmq", "envelope", 0.06),
        ("kafka", "waveform.path", 0.72),
        ("elastic", "magnifyingglass", 0.13),
        ("grafana", "chart.xyaxis.line", 0.07),
        ("prometheus", "flame", 0.05),
        ("mailpit", "envelope", 0.55),
        ("mailhog", "envelope", 0.55),
        ("node", "hexagon", 0.28),
        ("python", "chevron.left.forwardslash.chevron.right", 0.15),
        ("golang", "chevron.left.forwardslash.chevron.right", 0.52),
        ("ruby", "diamond", 0.99),
        ("php", "chevron.left.forwardslash.chevron.right", 0.70),
        ("alpine", "mountain.2", 0.55),
        ("ubuntu", "circle.hexagongrid", 0.05),
        ("debian", "circle.hexagongrid", 0.97),
        ("busybox", "terminal", 0.60),
        ("registry", "shippingbox", 0.60),
        ("vault", "lock", 0.50),
        ("keycloak", "key", 0.60),
        ("n8n", "point.3.connected.trianglepath.dotted", 0.90),
        ("ollama", "brain", 0.75),
    ]

    /// Derives the appearance for an image reference such as `docker.io/library/postgres:17`.
    public static func of(image: String) -> ImageAppearance {
        let name = repositoryName(from: image)
        let haystack = name.lowercased()
        if let match = known.first(where: { haystack.contains($0.match) }) {
            return ImageAppearance(symbol: match.symbol, monogram: monogram(for: name), hue: match.hue)
        }
        return ImageAppearance(symbol: nil, monogram: monogram(for: name), hue: hue(for: haystack))
    }

    /// `docker.io/library/postgres:17-alpine` → `postgres`.
    public static func repositoryName(from image: String) -> String {
        var text = image
        if let at = text.firstIndex(of: "@") { text = String(text[..<at]) }
        if let slash = text.lastIndex(of: "/") { text = String(text[text.index(after: slash)...]) }
        if let colon = text.firstIndex(of: ":") { text = String(text[..<colon]) }
        return text.isEmpty ? image : text
    }

    private static func monogram(for name: String) -> String {
        let letters = name.filter { $0.isLetter || $0.isNumber }
        return String(letters.prefix(2)).uppercased()
    }

    /// A stable hue from the name: the same image always gets the same colour, and neighbouring
    /// names don't collide the way a plain hash bucket would.
    private static func hue(for name: String) -> Double {
        var accumulator: UInt64 = 5381
        for byte in name.utf8 {
            accumulator = (accumulator &* 33) &+ UInt64(byte)
        }
        return Double(accumulator % 360) / 360
    }
}
