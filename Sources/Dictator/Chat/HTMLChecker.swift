import Foundation
import WebKit

/// Loads an HTML file the assistant wrote and reports what is actually wrong
/// with it.
///
/// **Why this exists, and why it isn't just a JavaScript error check.** The
/// failure that prompted it: asked three times for a click-through slide
/// presentation, the model produced a file whose JavaScript threw nothing at
/// all. Its stylesheet used `slide`, `controls`, `progress-bar` as *element*
/// selectors while the markup used `class="…"`, so `.slide { display: none }`
/// never applied, every slide rendered stacked, and the controls were never
/// positioned. A console-error check would have reported a clean bill of
/// health and the model would have told the user it worked — again. So the
/// two most useful things this reports are **CSS rules that match nothing**
/// and **what is actually visible after load**; script errors matter, but they
/// were never the problem.
///
/// **Containment.** This executes JavaScript the model wrote, so the page gets
/// no way to reach anything:
///
/// - Loaded with `loadFileURL(_:allowingReadAccessTo:)` scoped to the chat's
///   own folder, so `<link>`, `<script src>` and `<img>` reach the sibling
///   files the model also wrote and nothing else on disk.
/// - A `WKContentRuleList` blocks every `http`, `https`, `ws` and `wss` load.
///   That is stricter than `WebFetcher`'s private-range rules, because here
///   the page never gets to choose a host at all. A blocked CDN is *reported*
///   rather than allowed — the model needs to know why `Chart` is undefined,
///   and a checker that can't phone out is the thing that makes running
///   model-authored JavaScript acceptable without asking permission first.
/// - A non-persistent data store and a fresh process pool per check, so
///   nothing survives between runs.
/// - No `WKUIDelegate`, which makes `alert`, `confirm`, `prompt` and
///   `window.open` no-ops instead of hangs.
///
/// **Runaway scripts.** A page running `while (true)` does not block the
/// host's main thread, but `evaluateJavaScript` against it never returns — so
/// every call into the page races a watchdog, and on expiry the web view is
/// dropped, which (with a private process pool) reaps the WebContent process.
@MainActor
final class HTMLChecker {
    /// How long the whole check may take before it's abandoned.
    private static let hardLimit: Duration = .seconds(10)
    /// Navigation alone.
    private static let loadLimit: Duration = .seconds(5)
    /// Let load handlers, the first `requestAnimationFrame` and `setTimeout(0)`
    /// initialisation run before looking. Measured: a real page needed ~300ms.
    private static let settle: Duration = .milliseconds(500)
    /// Reading the page back, once it has settled.
    private static let reportLimit: Duration = .seconds(3)
    /// The result rides in the prompt on every later round, so it stays small.
    private static let maximumReportCharacters = 1_800

    /// Checks one file and returns the text handed to the model.
    static func check(fileURL: URL, readAccessTo folder: URL) async -> String {
        let checker = HTMLChecker()
        defer { checker.tearDown() }
        do {
            return try await checker.run(fileURL: fileURL, folder: folder)
        } catch is TimedOut {
            return """
                check_html: \(fileURL.lastPathComponent) — the page's scripts did not finish \
                within \(Self.hardLimit.components.seconds) seconds. That almost always means a \
                loop that never ends. Find it before changing anything else.
                """
        } catch {
            return "ERROR: couldn't check \(fileURL.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private struct TimedOut: Error {}

    private var webView: WKWebView?
    private var navigator: Navigator?

    private func run(fileURL: URL, folder: URL) async throws -> String {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // Its own pool: sharing one with the search engine would let a spinning
        // page take search down with it.
        configuration.processPool = WKProcessPool()
        if let blockEverything = await Self.networkBlockList() {
            configuration.userContentController.add(blockEverything)
        }
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Self.collectorJS, injectionTime: .atDocumentStart,
                forMainFrameOnly: true))

        let page = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: configuration)
        let delegate = Navigator()
        page.navigationDelegate = delegate
        webView = page
        navigator = delegate

        try await withDeadline(Self.loadLimit) {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                delegate.finish = { continuation.resume(with: $0) }
                page.loadFileURL(fileURL, allowingReadAccessTo: folder)
            }
        }

        try await Task.sleep(for: Self.settle)

        let raw = try await withDeadline(Self.reportLimit) { [weak self] in
            guard let page = self?.webView else { throw TimedOut() }
            return try await page.evaluateJavaScript(Self.reportJS) as? String
        }
        guard let raw, let data = raw.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return "ERROR: \(fileURL.lastPathComponent) loaded but couldn't be inspected."
        }
        return Self.describe(payload, name: fileURL.lastPathComponent)
    }

    private func tearDown() {
        navigator?.finish = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.configuration.userContentController.removeAllUserScripts()
        webView?.configuration.userContentController.removeAllContentRuleLists()
        // Dropping the view with a private pool reaps the WebContent process,
        // which is the only way to stop a page that is still spinning.
        webView = nil
        navigator = nil
    }

    /// Races an operation against a watchdog. A WebKit call against a spinning
    /// page never returns, so nothing may be awaited without one.
    private func withDeadline<T: Sendable>(
        _ limit: Duration, _ operation: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        let work = Task { @MainActor in try await operation() }
        let watchdog = Task { @MainActor in
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled else { return }
            work.cancel()
            self.navigator?.fail(with: TimedOut())
        }
        defer { watchdog.cancel() }
        do {
            return try await work.value
        } catch is CancellationError {
            throw TimedOut()
        }
    }

    // MARK: - Navigation

    private final class Navigator: NSObject, WKNavigationDelegate {
        var finish: ((Result<Void, Error>) -> Void)?

        private func complete(_ result: Result<Void, Error>) {
            let handler = finish
            finish = nil
            handler?(result)
        }

        func fail(with error: Error) { complete(.failure(error)) }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            complete(.success(()))
        }
        func webView(
            _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
        ) { complete(.failure(error)) }
        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) { complete(.failure(error)) }
    }

    // MARK: - Network block

    private static var cachedRuleList: WKContentRuleList?

    /// Blocks every network scheme. Compiled once and reused; a failure here
    /// returns nil and the check still runs — a page that can reach the web is
    /// worse than one that can't, but it is not a reason to refuse to check.
    private static func networkBlockList() async -> WKContentRuleList? {
        if let cachedRuleList { return cachedRuleList }
        // One rule per scheme: WebKit's content-blocker regex engine rejects
        // alternation outright ("Disjunctions are not supported yet"), and a
        // rule list that fails to compile blocks nothing at all — which is how
        // the first version of this silently let a CDN script through.
        let rules = """
            [{"trigger": {"url-filter": "^https?://"}, "action": {"type": "block"}},
             {"trigger": {"url-filter": "^wss?://"}, "action": {"type": "block"}},
             {"trigger": {"url-filter": "^ftps?://"}, "action": {"type": "block"}}]
            """
        do {
            let list = try await WKContentRuleListStore.default()?
                .compileContentRuleList(
                    forIdentifier: "DictatorHTMLCheck", encodedContentRuleList: rules)
            cachedRuleList = list
            return list
        } catch {
            NSLog("[Dictator] check_html network block failed to compile: \(error)")
            return nil
        }
    }

    // MARK: - Injected JavaScript

    /// Installed before any of the page's own script runs, so nothing is missed.
    private static let collectorJS = #"""
    (() => {
      const box = { errors: [], rejections: [], console: [], resources: [] };
      window.__dictatorCheck = box;
      const cap = (list, item) => { if (list.length < 12) list.push(item); };

      window.addEventListener('error', (event) => {
        // A resource that failed to load reports on the element, not as an
        // Error — that is how a blocked CDN script surfaces.
        if (event.target && event.target !== window && event.target.tagName) {
          const el = event.target;
          cap(box.resources, (el.tagName || '').toLowerCase() + ' ' +
              (el.src || el.href || '(no address)'));
          return;
        }
        cap(box.errors, (event.message || 'Error') +
            (event.lineno ? ' (line ' + event.lineno + ')' : ''));
      }, true);

      window.addEventListener('unhandledrejection', (event) => {
        cap(box.rejections, String((event.reason && event.reason.message) || event.reason));
      });

      for (const level of ['error', 'warn']) {
        const original = console[level];
        console[level] = function (...args) {
          cap(box.console, level + ': ' + args.map(String).join(' '));
          return original.apply(console, args);
        };
      }
    })()
    """#

    /// Run once the page has settled. Returns JSON.
    private static let reportJS = #"""
    (() => {
      const box = window.__dictatorCheck || { errors: [], rejections: [], console: [], resources: [] };

      // Rules that match nothing. The common cause is a stylesheet and its
      // markup disagreeing about classes versus element names, which renders
      // a page that looks broken while throwing nothing.
      const dead = [];
      let unreadableSheets = 0;
      for (const sheet of document.styleSheets) {
        let rules;
        try { rules = sheet.cssRules; } catch (e) { unreadableSheets++; continue; }
        if (!rules) continue;
        for (const rule of rules) {
          if (!rule.selectorText) continue;
          for (const part of rule.selectorText.split(',')) {
            // Strip pseudo-classes and pseudo-elements: they legitimately
            // match nothing at rest and would swamp the list.
            const base = part.trim().replace(/::?[a-zA-Z-]+(\([^)]*\))?/g, '').trim();
            if (!base || dead.includes(base) || dead.length >= 12) continue;
            let matched = 0;
            try { matched = document.querySelectorAll(base).length; } catch (e) { continue; }
            if (matched === 0) dead.push(base);
          }
        }
      }

      // What a person would actually see. Compared against what the model
      // intended, this is what catches "all four slides are stacked".
      const seen = [];
      for (const el of document.querySelectorAll('[id], [class]')) {
        if (seen.length >= 14) break;
        const style = getComputedStyle(el);
        const rect = el.getBoundingClientRect();
        const hidden = style.display === 'none' || style.visibility === 'hidden' ||
                       parseFloat(style.opacity) === 0 || (rect.width === 0 && rect.height === 0);
        const name = (el.tagName || '').toLowerCase() +
                     (el.id ? '#' + el.id : '') +
                     (el.className && typeof el.className === 'string'
                        ? '.' + el.className.trim().split(/\s+/).join('.') : '');
        seen.push(name + (hidden ? ' hidden' : ' visible ' + Math.round(rect.width) + 'x' +
                  Math.round(rect.height) + ' at y=' + Math.round(rect.top)));
      }

      // Inline handlers pointing at functions that don't exist. This is the
      // single most common way a generated page looks fine and does nothing:
      // the functions get defined inside DOMContentLoaded or a module, so
      // onclick="showSlide(1)" can never see them. The error only happens when
      // the user clicks, so nothing is thrown during a check.
      const handlers = [];
      const attrs = ['onclick', 'onchange', 'oninput', 'onsubmit', 'onkeydown', 'onkeyup'];
      for (const el of document.querySelectorAll('*')) {
        if (handlers.length >= 8) break;
        for (const attr of attrs) {
          const code = el.getAttribute && el.getAttribute(attr);
          if (!code) continue;
          const match = code.match(/([A-Za-z_$][\w$]*)\s*\(/);
          if (!match) continue;
          const fn = match[1];
          if (['alert','confirm','prompt','return','if','for','while','this'].includes(fn)) continue;
          if (typeof window[fn] !== 'function' && handlers.indexOf(fn) === -1) handlers.push(fn);
        }
      }

      return JSON.stringify({
        handlers: handlers,
        title: document.title || '',
        readyState: document.readyState,
        errors: box.errors, rejections: box.rejections,
        console: box.console, resources: box.resources,
        dead: dead, unreadableSheets: unreadableSheets,
        elements: seen,
        elementTotal: document.querySelectorAll('[id], [class]').length
      });
    })()
    """#

    // MARK: - Report

    /// Verdict first, then numbered findings, each line standing on its own.
    /// A small model acts on "these eight selectors match nothing"; it does not
    /// act on a wall of JSON.
    private static func describe(_ payload: [String: Any], name: String) -> String {
        let errors = (payload["errors"] as? [String] ?? []).map(clean)
        let rejections = (payload["rejections"] as? [String] ?? []).map(clean)
        let consoleLines = (payload["console"] as? [String] ?? []).map(clean)
        let resources = (payload["resources"] as? [String] ?? []).map(clean)
        let dead = (payload["dead"] as? [String] ?? []).map(clean)
        let elements = (payload["elements"] as? [String] ?? []).map(clean)

        var findings: [String] = []
        if !dead.isEmpty {
            findings.append(
                "CSS rules that match nothing in the page (\(dead.count)): "
                    + dead.joined(separator: ", ")
                    + "\n   Usually the stylesheet and the markup disagree — for example a class "
                    + "in the HTML (class=\"slide\") but a bare element name in the CSS (slide { … }), "
                    + "which needs a dot (.slide { … }).")
        }
        let handlers = (payload["handlers"] as? [String] ?? []).map(clean)
        if !handlers.isEmpty {
            findings.append(
                "Buttons call functions that don't exist when clicked (\(handlers.count)): "
                    + handlers.map { "\($0)()" }.joined(separator: ", ")
                    + "\n   Nothing throws until the user clicks. This is usually because the "
                    + "functions are defined inside a DOMContentLoaded handler, a module, or "
                    + "another scope — an onclick=\"…\" attribute can only reach functions "
                    + "defined at the top level. Either define them at the top level (or assign "
                    + "them to window), or attach the handlers with addEventListener instead.")
        }
        if !errors.isEmpty {
            // macOS reports a local file's script errors as the opaque "Script
            // error.": the page's own origin is unique, so the details are
            // withheld. Unmasking needs file access widened to the whole disk,
            // which is not a trade worth making for a nicer message — so say
            // what is known and point at what else the check found.
            let masked = errors.allSatisfy { $0.hasPrefix("Script error") }
            if masked {
                findings.append(
                    "A script threw an error while the page loaded (\(errors.count)). macOS "
                        + "doesn't reveal which, for a file opened locally. Look for a name used "
                        + "before it's defined or an element fetched before it exists — and see "
                        + "how far the page got from the list below.")
            } else {
                findings.append(
                    "JavaScript errors (\(errors.count)): " + errors.joined(separator: "; "))
            }
        }
        if !rejections.isEmpty {
            findings.append("Unhandled promise rejections: " + rejections.joined(separator: "; "))
        }
        if !consoleLines.isEmpty {
            findings.append("Console: " + consoleLines.joined(separator: "; "))
        }
        if !resources.isEmpty {
            findings.append(
                "Could not load (\(resources.count)): " + resources.joined(separator: ", ")
                    + "\n   This check blocks the internet, so anything from a CDN will always "
                    + "fail here. It works when the user opens the file themselves — but code "
                    + "depending on it did not run during this check.")
        }
        if let unreadable = payload["unreadableSheets"] as? Int, unreadable > 0 {
            findings.append(
                "\(unreadable) linked stylesheet(s) could not be inspected, so their rules "
                    + "weren't checked. Inline <style> can always be checked.")
        }

        var report = findings.isEmpty
            ? "check_html: \(name) — loaded with no errors."
            : "check_html: \(name) — \(findings.count) problem\(findings.count == 1 ? "" : "s") found."
        for (index, finding) in findings.enumerated() {
            report += "\n\(index + 1). \(finding)"
        }
        if !elements.isEmpty {
            report += "\nOn screen after load: " + elements.joined(separator: "; ")
            if let total = payload["elementTotal"] as? Int, total > elements.count {
                report += " (…and \(total - elements.count) more)"
            }
        }
        report += "\nA clean load is not proof it works — compare the list above with what you "
            + "intended to appear."

        guard report.count > maximumReportCharacters else { return report }
        return String(report.prefix(maximumReportCharacters)) + "\n…[report truncated]"
    }

    /// Element ids, titles and console text are page-controlled. The page is
    /// the model's own, so injection is circular — but a stray `>>>` would
    /// still corrupt the fence around any tool result it lands in.
    private static func clean(_ text: String) -> String {
        var out = text
        for fence in ["<<<", ">>>"] { out = out.replacingOccurrences(of: fence, with: "") }
        out = out.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return String(out.trimmingCharacters(in: .whitespacesAndNewlines).prefix(180))
    }
}
