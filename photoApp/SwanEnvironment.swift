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

    /// The Swan page. Must be https: the camera needs a secure context.
    var pageURL: URL {
        switch self {
        case .sandbox: return URL(string: "https://swan-mobile-web-component.swan.so/v1.3.15/index.html")!
        case .production: return URL(string: "https://swan-mobile-web-component.swan.so/v1.3.15/index.html")!
        }
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
        case .sandbox: return "sw_pk_82ea4cb0719240c1a07c559eda5924a0"
        case .production: return "sw_pk_82ea4cb0719240c1a07c559eda5924a0"
        }
    }

    /// Where each scan's JSON report is posted, and the ingest key (see `ScanReport`). Sandbox
    /// builds only. The key ships inside the app; it keeps out casual traffic and nothing more.
    var scanReport: (url: URL, key: String)? {
        switch self {
        case .sandbox: return (URL(string: "https://devphotoingest.api.swanvision.ai/v1/scans")!,
                               "a1e5074c29a3c3da344212996765c566e30c7b99cd0a6e81")
        case .production: return nil
        }
    }
}
