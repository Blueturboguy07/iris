#if DEBUG
import Foundation
import WebKit
import os

/// DEBUG builds only (the whole file is compiled out of Release): forwards a
/// downloaded web app's `console.error`, `console.warn`, `console.log`,
/// uncaught errors (`window.onerror` and resource load failures) and
/// unhandled promise rejections to the unified log, so a failure on a
/// device or Simulator is visible with `log stream` instead of silent.
///
/// This is a one-way, log-only channel. The page can only append text to the
/// log; nothing is returned to the page, no native capability is exposed, and
/// the handler never reads or changes app data. Release builds contain no
/// script-message handler at all.
///
/// Read it with, for example:
///   log stream --level info --predicate 'subsystem == "com.publikhq.iris.mobileshell" AND category == "web-console"'
enum NativeWebConsoleBridge {
    static let subsystem = "com.publikhq.iris.mobileshell"
    static let category = "web-console"
    static let messageHandlerName = "irisDebugConsole"
    /// Longest single message forwarded; the rest is summarized as a count.
    static let maximumMessageCharacters = 4000
    /// The unified log keeps only about 1 KB of one dynamic string, so a long
    /// message (a stack trace, say) is split into numbered parts this size.
    static let maximumLogLineBytes = 900
    /// Levels the page script may send; anything else is dropped.
    static let allowedLevels: Set<String> = [
        "error", "warn", "log", "uncaught", "unhandledrejection", "resource-error",
    ]

    struct Entry: Equatable {
        let level: String
        let message: String
    }

    /// Validates one page message. Returns nil for anything that is not the
    /// exact shape the bundled script sends, so a page cannot inject other
    /// log levels or non-text payloads.
    static func decode(messageBody: Any) -> Entry? {
        guard let body = messageBody as? [String: Any],
              let level = body["level"] as? String, allowedLevels.contains(level),
              let message = body["message"] as? String else { return nil }
        return Entry(level: level, message: truncated(message))
    }

    static func truncated(_ message: String) -> String {
        guard message.count > maximumMessageCharacters else { return message }
        let kept = String(message.prefix(maximumMessageCharacters))
        return kept + " ... [truncated \(message.count - maximumMessageCharacters) chars]"
    }

    /// One log line, prefixed with the app id so several apps can be told
    /// apart in one stream: `[publik.kneecap] console.error: ...`.
    static func formatLine(appID: String, entry: Entry) -> String {
        let label: String
        switch entry.level {
        case "error", "warn", "log": label = "console.\(entry.level)"
        case "uncaught": label = "window.onerror"
        default: label = entry.level
        }
        return "[\(appID)] \(label): \(entry.message)"
    }

    /// The log lines for one message: the formatted line itself, or, when it
    /// is longer than the unified log keeps, numbered parts of it, each
    /// still prefixed with the app id.
    static func logLines(appID: String, entry: Entry) -> [String] {
        let line = formatLine(appID: appID, entry: entry)
        guard line.utf8.count > maximumLogLineBytes else { return [line] }
        var parts: [String] = []
        var current = ""
        var currentBytes = 0
        for character in line {
            let size = character.utf8.count
            if currentBytes + size > maximumLogLineBytes, !current.isEmpty {
                parts.append(current)
                current = ""
                currentBytes = 0
            }
            current.append(character)
            currentBytes += size
        }
        if !current.isEmpty { parts.append(current) }
        return parts.enumerated().map { index, part in
            index == 0
                ? "\(part) [part 1/\(parts.count)]"
                : "[\(appID)] (part \(index + 1)/\(parts.count)) \(part)"
        }
    }

    static func osLogType(for level: String) -> OSLogType {
        switch level {
        case "log": return .info
        case "warn": return .default
        default: return .error
        }
    }

    /// Installs the page script and the log-only handler. Call once per
    /// configuration, before the web view is created.
    @MainActor
    static func install(into configuration: WKWebViewConfiguration, appID: String) {
        let controller = configuration.userContentController
        controller.add(LogHandler(appID: appID), contentWorld: .page, name: messageHandlerName)
        controller.addUserScript(WKUserScript(source: pageScript, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: .page))
    }

    /// Removes the handler so the page's reference cannot outlive the view.
    @MainActor
    static func uninstall(from webView: WKWebView) {
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: messageHandlerName, contentWorld: .page)
    }

    /// Host-side facts about the same app, in the same log stream (for
    /// example a WebContent process termination or an open panel result).
    static func logHostEvent(appID: String, _ event: String) {
        Logger(subsystem: subsystem, category: category)
            .notice("[\(appID, privacy: .public)] host: \(event, privacy: .public)")
    }

    @MainActor
    private final class LogHandler: NSObject, WKScriptMessageHandler {
        private let appID: String
        private let logger = Logger(subsystem: NativeWebConsoleBridge.subsystem,
                                    category: NativeWebConsoleBridge.category)

        init(appID: String) { self.appID = appID }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let entry = NativeWebConsoleBridge.decode(messageBody: message.body) else { return }
            let type = NativeWebConsoleBridge.osLogType(for: entry.level)
            for line in NativeWebConsoleBridge.logLines(appID: appID, entry: entry) {
                // DEBUG only: public so `log stream` shows the text instead of <private>.
                logger.log(level: type, "\(line, privacy: .public)")
            }
        }
    }

    /// Wraps the page's console methods and listens for uncaught errors.
    /// Never throws into the page, always calls the original console method,
    /// and caps volume per second (400 log/warn lines and, separately, 200
    /// error lines, so a console.log flood can never hide an uncaught error),
    /// then reports a dropped count.
    static let pageScript = """
    (() => {
      const handlers = globalThis.webkit && globalThis.webkit.messageHandlers;
      const handler = handlers && handlers.\(messageHandlerName);
      if (!handler || globalThis.__irisDebugConsoleInstalled) return;
      Object.defineProperty(globalThis, '__irisDebugConsoleInstalled', { value: true });
      const budgets = { log: { limit: 400, sent: 0, dropped: 0 }, error: { limit: 200, sent: 0, dropped: 0 } };
      let windowStart = Date.now(), flushTimer = null;
      const flush = () => {
        flushTimer = null;
        for (const name of Object.keys(budgets)) {
          const budget = budgets[name];
          if (budget.dropped > 0) {
            try { handler.postMessage({ level: 'warn', message: '[iris-debug-console] dropped ' + budget.dropped + ' ' + name + ' messages (rate limit)' }); } catch (_) {}
          }
          budget.sent = 0; budget.dropped = 0;
        }
        windowStart = Date.now();
      };
      const describe = (value) => {
        try {
          if (typeof value === 'string') return value;
          if (value === undefined) return 'undefined';
          if (value === null) return 'null';
          if (value instanceof Error) {
            return (value.name || 'Error') + ': ' + value.message + (value.stack ? '\\n' + value.stack : '');
          }
          if (typeof value === 'function') return '[function ' + (value.name || 'anonymous') + ']';
          if (typeof value !== 'object') return String(value);
          if (typeof File !== 'undefined' && value instanceof File) {
            return '[File name=' + value.name + ' size=' + value.size + ' type=' + value.type + ']';
          }
          if (typeof Blob !== 'undefined' && value instanceof Blob) {
            return '[Blob size=' + value.size + ' type=' + value.type + ']';
          }
          if (value instanceof ArrayBuffer) return '[ArrayBuffer ' + value.byteLength + ' bytes]';
          if (ArrayBuffer.isView(value)) return '[' + value.constructor.name + ' ' + value.byteLength + ' bytes]';
          if (typeof Event !== 'undefined' && value instanceof Event) return '[Event ' + value.type + ']';
          const seen = new WeakSet();
          return JSON.stringify(value, (key, item) => {
            if (typeof item === 'bigint') return item.toString();
            if (item instanceof Error) return (item.name || 'Error') + ': ' + item.message;
            if (typeof item === 'object' && item !== null) {
              if (seen.has(item)) return '[circular]';
              seen.add(item);
            }
            return item;
          });
        } catch (error) {
          try { return String(value); } catch (_) { return '[unprintable]'; }
        }
      };
      const post = (level, parts) => {
        try {
          const now = Date.now();
          if (now - windowStart >= 1000) {
            if (flushTimer !== null) { clearTimeout(flushTimer); }
            flush();
          }
          const budget = (level === 'log' || level === 'warn') ? budgets.log : budgets.error;
          if (++budget.sent > budget.limit) {
            budget.dropped++;
            if (flushTimer === null) flushTimer = setTimeout(flush, Math.max(0, 1000 - (now - windowStart)));
            return;
          }
          let text = parts.map(describe).join(' ');
          if (text.length > \(maximumMessageCharacters + 64)) text = text.slice(0, \(maximumMessageCharacters + 64));
          handler.postMessage({ level: level, message: text });
        } catch (_) {}
      };
      for (const level of ['error', 'warn', 'log']) {
        const original = console[level];
        if (typeof original !== 'function') continue;
        console[level] = function (...args) {
          post(level, args);
          return original.apply(this, args);
        };
      }
      addEventListener('error', (event) => {
        if (typeof ErrorEvent !== 'undefined' && event instanceof ErrorEvent) {
          post('uncaught', [event.error instanceof Error ? event.error : event.message,
            'at ' + (event.filename || '?') + ':' + (event.lineno || 0) + ':' + (event.colno || 0)]);
          return;
        }
        const target = event.target;
        const source = target && (target.currentSrc || target.src || target.href);
        if (source) post('resource-error', ['failed to load ' + (target.tagName || 'resource') + ' ' + source]);
      }, true);
      addEventListener('unhandledrejection', (event) => { post('unhandledrejection', [event.reason]); });
    })();
    """
}
#endif
