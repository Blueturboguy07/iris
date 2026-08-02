//
//  ExternalLinkPolicy.swift
//  leanring-buddy
//
//  Decides which links a guide step is allowed to open in the user's browser.
//  Ported from `open_external` and `allowed_external_host` in
//  `iris-desktop/src-tauri/src/main.rs` (lines 470-533), which remains the
//  behavioral spec.
//

import AppKit
import Foundation

enum ExternalLinkPolicy {
    /// Every host a published guide can send the reader to.
    ///
    /// THIS IS THE ONE CANONICAL COPY OF THIS LIST. DO NOT ADD A SECOND ONE.
    /// The Tauri app kept the same allowlist in both Rust and JavaScript. The
    /// two drifted, and a guide step whose host had only been added to one of
    /// them opened nothing at all — "Install BrowserOS" in Astro's Windows
    /// branch read as a dead button rather than a blocked host. Any new host
    /// belongs here and nowhere else; every caller in this app must ask this
    /// type instead of keeping its own copy.
    static let allowedExternalHosts: Set<String> = [
        "publikhq.com",
        "www.publikhq.com",
        "github.com",
        "docs.github.com",
        "git-scm.com",
        "nodejs.org",
        "www.python.org",
        "python.org",
        "rustup.rs",
        "docker.com",
        "www.docker.com",
        "docs.docker.com",
        "developer.apple.com",
        "learn.microsoft.com",
        // Toolchains and assets the current guides link to.
        "apps.apple.com",
        "developer.android.com",
        "huggingface.co",
        "visualstudio.microsoft.com",
        "cmake.org",
        "www.cmake.org",
        // Astro's Windows route. Missing here, "Install BrowserOS" — step 2 of
        // that branch — opened nothing at all in the desktop app.
        "files.browseros.com",
        "go.dev",
    ]

    /// The two hosts a developer running the publik site locally needs, which
    /// are the only reason plain `http` is ever accepted.
    private static let allowedLocalDevelopmentHosts: Set<String> = ["localhost", "127.0.0.1"]

    /// A fragment longer than this is a payload rather than an anchor.
    private static let maximumFragmentLength = 512

    /// Host-only check, matching `allowed_external_host` (main.rs:503-533). The
    /// comparison is on the whole host after lowercasing, so a lookalike such as
    /// `github.com.evil.tld` is not a member and never will be.
    static func isAllowedExternalHost(_ host: String) -> Bool {
        allowedExternalHosts.contains(host.lowercased())
    }

    /// The full check `open_external` performs before handing a URL to the OS.
    static func isAllowedExternalURL(_ externalURLString: String) -> Bool {
        guard let externalURL = URL(string: externalURLString),
              let urlComponents = URLComponents(url: externalURL, resolvingAgainstBaseURL: false) else {
            return false
        }

        // Credentials in a guide link are always someone else's idea, and an
        // oversized fragment is how a payload rides along to the browser.
        if let user = urlComponents.user, !user.isEmpty {
            return false
        }
        if urlComponents.password != nil {
            return false
        }
        if let fragment = urlComponents.fragment, fragment.count > maximumFragmentLength {
            return false
        }

        guard let host = urlComponents.host, !host.isEmpty else {
            return false
        }
        let scheme = urlComponents.scheme?.lowercased()
        let lowercasedHost = host.lowercased()

        // Published guides must be https. Plain http survives only for a site
        // running on this machine, where there is no network to intercept.
        let isAllowedPublishedHost = scheme == "https" && isAllowedExternalHost(lowercasedHost)
        let isAllowedLocalDevelopmentHost = (scheme == "http" || scheme == "https")
            && allowedLocalDevelopmentHosts.contains(lowercasedHost)
        return isAllowedPublishedHost || isAllowedLocalDevelopmentHost
    }

    /// Opens the link in the user's default browser, but only if the policy
    /// above allows it. Returns whether the link was actually handed to the OS
    /// so a caller can tell the user why nothing happened.
    @discardableResult
    @MainActor
    static func openExternalURLIfAllowed(_ externalURLString: String) -> Bool {
        guard isAllowedExternalURL(externalURLString),
              let externalURL = URL(string: externalURLString) else {
            return false
        }
        return NSWorkspace.shared.open(externalURL)
    }
}
