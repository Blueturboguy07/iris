#if os(iOS)
import CryptoKit
import Darwin
import Foundation
import IrisMobileShellCore
import WebKit

/// Read-only access to the *already verified package's declared resources*.
/// This is not a native API bridge, arbitrary file server or remote proxy. The
/// document stays at its original file URL so existing browser data is retained.
@MainActor
final class NativePackageResourceHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "iris-resource"
    private let host = UUID().uuidString.lowercased()
    private let root: URL
    private let receipts: [String: NativeVerifiedResourceReceipt]
    private var pending: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var valid = true

    init(launch: VerifiedLaunchDescriptor) {
        root = launch.readAccessRootURL
        receipts = Dictionary(uniqueKeysWithValues: launch.resources.map { ($0.path, $0) })
    }

    func install(into configuration: WKWebViewConfiguration) throws {
        let configurationJSON = try JSONSerialization.data(withJSONObject: [
            "root": root.absoluteString.hasSuffix("/") ? root.absoluteString : root.absoluteString + "/",
            "origin": Self.scheme + "://" + host + "/",
            "paths": Array(receipts.keys).sorted(),
        ], options: [.sortedKeys])
        guard let json = String(data: configurationJSON, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
        configuration.setURLSchemeHandler(self, forURLScheme: Self.scheme)
        let source = """
        (() => {
          const c = \(json), allowed = new Set(c.paths), original = globalThis.fetch.bind(globalThis);
          function resourceURL(value) {
            const u = new URL(value, document.baseURI);
            if (u.protocol !== 'file:') return null;
            if (!u.href.startsWith(c.root)) throw new TypeError('Resource is outside this app package');
            const relative = decodeURIComponent(u.pathname.slice(new URL(c.root).pathname.length));
            if (!allowed.has(relative)) throw new TypeError('Resource is not declared in this app package');
            return c.origin + relative.split('/').map(encodeURIComponent).join('/');
          }
          const fetchResource = (input, options) => {
            try {
              const request = input instanceof Request ? input : null;
              const target = resourceURL(request ? request.url : String(input));
              if (!target) return original(input, options);
              const method = String(options?.method || request?.method || 'GET').toUpperCase();
              if (method !== 'GET' && method !== 'HEAD') return Promise.reject(new TypeError('Package resources are read-only'));
              return original(target, {method, mode:'cors', credentials:'omit',
                signal: options?.signal || request?.signal, cache:'no-store'});
            } catch (error) { return Promise.reject(error); }
          };
          Object.defineProperty(globalThis, 'fetch', {value:fetchResource, writable:false, configurable:false});
          Object.defineProperty(globalThis, 'IrisPackageAssets', {value:Object.freeze({
            url: path => { const value = resourceURL(path); if (!value) throw new TypeError('Only packaged resources are supported'); return value; }
          }), writable:false, configurable:false});
        })();
        """
        configuration.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let identifier = ObjectIdentifier(urlSchemeTask as AnyObject)
        guard valid, pending.count < 4,
              let url = urlSchemeTask.request.url,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == Self.scheme, parts.host == host,
              parts.port == nil, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              ["GET", "HEAD"].contains(urlSchemeTask.request.httpMethod ?? "GET"),
              parts.path.hasPrefix("/"), let receipt = receipts[String(parts.path.dropFirst())] else {
            urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile)); return
        }
        let root = self.root
        pending[identifier] = Task { [weak self] in
            do {
                let bytes = try await Task.detached(priority: .userInitiated) {
                    try Self.verifiedBytes(root: root, receipt: receipt)
                }.value
                guard let self, valid, pending[identifier] != nil, !Task.isCancelled else { return }
                guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                    "Content-Type": receipt.mediaType,
                    "Content-Length": String(bytes.count),
                    "Access-Control-Allow-Origin": "*",
                    "Cache-Control": "no-store",
                    "X-Content-Type-Options": "nosniff"
                ]) else { throw URLError(.badServerResponse) }
                pending.removeValue(forKey: identifier)
                urlSchemeTask.didReceive(response)
                if urlSchemeTask.request.httpMethod != "HEAD" { urlSchemeTask.didReceive(bytes) }
                urlSchemeTask.didFinish()
            } catch {
                guard let self, valid, pending.removeValue(forKey: identifier) != nil, !Task.isCancelled else { return }
                urlSchemeTask.didFailWithError(URLError(.cannotDecodeContentData))
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        pending.removeValue(forKey: ObjectIdentifier(urlSchemeTask as AnyObject))?.cancel()
    }

    func close() {
        valid = false
        for task in pending.values { task.cancel() }
        pending.removeAll()
    }

    nonisolated private static func verifiedBytes(root: URL, receipt: NativeVerifiedResourceReceipt) throws -> Data {
        guard (0...(16 * 1024 * 1024)).contains(receipt.bytes) else { throw URLError(.dataLengthExceedsMaximum) }
        let components = receipt.path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw URLError(.noPermissionsToReadFile)
        }
        var directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw URLError(.fileDoesNotExist) }
        defer { Darwin.close(directory) }
        for part in components.dropLast() {
            let next = openat(directory, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw URLError(.noPermissionsToReadFile) }
            Darwin.close(directory); directory = next
        }
        let descriptor = openat(directory, String(components.last!), O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw URLError(.fileDoesNotExist) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size == receipt.bytes else { throw URLError(.cannotDecodeContentData) }
        let bytes = try handle.read(upToCount: receipt.bytes + 1) ?? Data()
        guard bytes.count == receipt.bytes,
              "sha256:" + SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == receipt.sha256 else {
            throw URLError(.cannotDecodeContentData)
        }
        return bytes
    }
}
#endif
