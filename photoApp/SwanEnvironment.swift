// Swan Gallery Pick: the values that differ between a sandbox build and a production build.

import Foundation

/// Chosen by the build: the Sandbox configuration (which sets `SWAN_SANDBOX`) uses `.sandbox`,
/// Production uses `.production`. A Debug build, where a project has one, counts as sandbox.
enum SwanEnvironment {
    case sandbox, production

    #if DEBUG || SWAN_SANDBOX
    static let current = SwanEnvironment.sandbox
    #else
    static let current = SwanEnvironment.production
    #warning("Fill in the production values in SwanEnvironment.swift, then delete this line.")
    #endif

    /// The Swan page. Must be https: the camera needs a secure context. Sandbox loads the dev CDN,
    /// whose versions are numbered separately from production's.
    var pageURL: URL {
        switch self {
        case .sandbox: return URL(string: "https://dhua7f26rck7x.cloudfront.net/v1.3.24/index.html")!
        case .production: return URL(string: "https://swan-mobile-web-component.swan.so/v1.3.20/index.html")!
        }
    }

    /// The version segment of `pageURL`, e.g. "v1.3.21".
    /// Empty in production, so only sandbox builds show it.
    var versionLabel: String {
        guard self == .sandbox else { return "" }
        return pageURL.pathComponents.first { $0.hasPrefix("v") && $0.count > 1 && $0.dropFirst().first?.isNumber == true } ?? ""
    }

    /// Where the sample mints session tokens. Must be the same environment as the page.
    var sessionURL: URL {
        switch self {
        case .sandbox: return URL(string: "https://swan-integration.swanvision.dev/api/session")!
        case .production: return URL(string: "https://swan-integration.swanvision.dev/api/session")!
        }
    }

    /// The sample's API key. A shipped app mints tokens on its own server and ships no key.
    var publishableKey: String {
        switch self {
        case .sandbox: return "sw_pk_77e0eaa18bdc4520be45bf2a0a2abf71"
        case .production: return "sw_pk_77e0eaa18bdc4520be45bf2a0a2abf71"
        }
    }

    /// Where each scan's JSON report is posted, and the ingest key (see `ScanReport`). Both builds
    /// post to the one ingest; the report's User-Agent names the environment so the ingest can tell
    /// them apart. The key ships inside the app; it keeps out casual traffic and nothing more.
    /// Return nil to turn reports off for a build.
    var scanReport: (url: URL, key: String)? {
        switch self {
        case .sandbox, .production: return (URL(string: "https://devphotoingest.api.swanvision.ai/v1/scans")!,
                                            "a1e5074c29a3c3da344212996765c566e30c7b99cd0a6e81")
        }
    }

    /// The environment segment of the report's User-Agent: "photoApp/ios/<build>/<env>".
    var reportEnvironment: String { self == .sandbox ? "sandbox" : "production" }
}
