#if os(iOS)
import Foundation
import IrisMobileShellCore
import WebKit

enum IrisPackagedAPIHostScriptError: Error {
    case missingSDKResource
    case unreadableSDKResource
    case invalidContext
    case adapterScopeMismatch
    case missingAdapterResource
    case unreadableAdapterResource
    case unavailableAdapter
}

public enum IrisPackagedAPIAdapterConfiguration: Equatable, Sendable {
    case notConfigured
    case offlineExample(identity: NativeShellAppIdentity, revisionId: String)
    case verifiedBundle(NativeVerifiedPackagedAPI)
    case unavailable
}

public extension NativePackagedAPIInstallationStore {
    /// For the existing Host-owned `packagedAPIAdapterForLaunch` resolver. A
    /// missing installation means optional API is not configured. An invalid or
    /// revoked installed package instead refuses the launch; it is not silently
    /// treated as absence and cannot substitute another revision's adapter.
    @MainActor
    func adapterConfiguration(for launch: VerifiedLaunchDescriptor) -> IrisPackagedAPIAdapterConfiguration {
        do {
            guard let installed = try installed(for: launch) else { return .notConfigured }
            return .verifiedBundle(installed)
        } catch {
            return .unavailable
        }
    }
}

@MainActor
enum IrisPackagedAPIHostScripts {
    private struct Context: Encodable {
        let appId: String
        let projectId: String
        let revisionId: String
    }

    private static let resourceName = "iris-packaged-api"
    private static let resourceExtension = "js"
    private static let offlineExampleResourceName = "iris-packaged-api-offline-example"
    private static let closeSource = "globalThis.IrisPackagedAPI?.v1?.close?.();"

    static func validateScope(_ configuration: IrisPackagedAPIAdapterConfiguration, for launch: VerifiedLaunchDescriptor) throws {
        switch configuration {
        case .notConfigured: return
        case .unavailable: throw IrisPackagedAPIHostScriptError.unavailableAdapter
        case .offlineExample(let identity, let revisionId):
            guard launch.identity == identity, launch.revisionId == revisionId else {
                throw IrisPackagedAPIHostScriptError.adapterScopeMismatch
            }
        case .verifiedBundle(let package):
            guard launch.identity == package.identity, launch.revisionId == package.revisionId else {
                throw IrisPackagedAPIHostScriptError.adapterScopeMismatch
            }
        }
    }

    static func install(
        into configuration: WKWebViewConfiguration,
        launch: VerifiedLaunchDescriptor,
        adapter: IrisPackagedAPIAdapterConfiguration = .notConfigured
    ) throws {
        let source = try source(launch: launch, adapter: adapter)
        configuration.userContentController.addUserScript(
            WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
    }

    static func close(in webView: WKWebView, completion: ((Error?) -> Void)? = nil) {
        webView.evaluateJavaScript(closeSource) { _, error in
            completion?(error)
        }
    }

    /// Internal test seam. The extra source runs before the canonical SDK in
    /// the same document-start script so tests can provide an offline adapter.
    /// Production callers use `install(into:launch:)` and provide no adapter.
    static func source(
        launch: VerifiedLaunchDescriptor,
        adapter: IrisPackagedAPIAdapterConfiguration = .notConfigured,
        testingBootstrapExtension: String? = nil
    ) throws -> String {
        let bootstrapSource = bootstrapSource()
        let packagedAdapter = try adapterSource(adapter, launch: launch)
        let verifiedContextSource = try verifiedContextSource(launch: launch)
        let sdk = try sdkSource()
        return [bootstrapSource, packagedAdapter, testingBootstrapExtension, verifiedContextSource, sdk]
            .compactMap { $0 }
            .joined(separator: "\n")
    }

    private static func bootstrapSource() -> String {
        "globalThis.__IRIS_PACKAGED_API_BOOTSTRAP__ = {};"
    }

    private static func verifiedContextSource(launch: VerifiedLaunchDescriptor) throws -> String {
        let json: String
        if let identity = launch.identity {
            let data = try JSONEncoder().encode(
                Context(appId: identity.appId, projectId: identity.projectId, revisionId: launch.revisionId)
            )
            guard let encoded = String(data: data, encoding: .utf8) else {
                throw IrisPackagedAPIHostScriptError.invalidContext
            }
            json = encoded
        } else {
            json = "null"
        }
        let contextValueExpression = json == "null" ? "null" : "Object.freeze(\(json))"
        return """
        (() => {
          const bootstrap = globalThis.__IRIS_PACKAGED_API_BOOTSTRAP__;
          Object.defineProperty(bootstrap, "context", {
            value: \(contextValueExpression),
            enumerable: true,
            writable: false,
            configurable: false
          });
          Object.freeze(bootstrap);
        })();
        """
    }

    private static func sdkSource() throws -> String {
        guard let url = Bundle.module.url(forResource: resourceName, withExtension: resourceExtension) else {
            throw IrisPackagedAPIHostScriptError.missingSDKResource
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw IrisPackagedAPIHostScriptError.unreadableSDKResource
        }
    }

    private static func adapterSource(
        _ configuration: IrisPackagedAPIAdapterConfiguration,
        launch: VerifiedLaunchDescriptor
    ) throws -> String? {
        try validateScope(configuration, for: launch)
        if case .verifiedBundle(let package) = configuration {
            return package.source
        }
        guard case .offlineExample = configuration else { return nil }
        guard let url = Bundle.module.url(
            forResource: offlineExampleResourceName,
            withExtension: resourceExtension,
            subdirectory: "Adapters"
        ) else {
            throw IrisPackagedAPIHostScriptError.missingAdapterResource
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw IrisPackagedAPIHostScriptError.unreadableAdapterResource
        }
    }
}
#endif
