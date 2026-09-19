import Foundation
import WebKit

/// DuckDuckGo's no-JavaScript endpoint, read through a real browser engine.
///
/// **Why a browser engine and not `URLSession`.** DuckDuckGo's bot wall is a
/// TLS/JS fingerprint check, not a User-Agent check. Measured from this Mac on
/// one residential IP: `curl` carrying a Safari UA string got results for one
/// or two queries and then an HTTP 202 challenge page, while a windowless
/// `WKWebView` returned ten results on seven of seven consecutive queries —
/// *while curl was still in its blocked state from the same address*. Setting
/// headers on a `URLSession` request does not close that gap, so don't try to
/// "simplify" this into one; the whole reason it works is that it is a real
/// engine with a real fingerprint.
///
/// **No settle delay.** The lite page is server-rendered, so results are in
/// the DOM by the time navigation finishes — measured 650-1000ms per search
/// end to end. The retry loop in `extract` is a safety net for the day that
/// stops being true, not a wait: the first attempt almost always succeeds.
///
/// **Ads are only identifiable by host.** A sponsored row carries no badge
/// class. It holds *two* links: the `duckduckgo.com/y.js?ad_domain=…`
/// redirect and a "more info" link to DuckDuckGo's own help pages. Filtering
/// just `y.js` therefore leaves the "more info" link behind, and the sibling
/// walk then staples the advert's copy onto it — measured, and it put two
/// adverts at the top of a results list looking like ordinary results. So the
/// rule is host-based: a real result never points at the engine itself.
@MainActor
final class DuckDuckGoLiteSearch {
    static let shared = DuckDuckGoLiteSearch()

    enum SearchError: LocalizedError {
        case challenged
        case navigation(String)
        case timedOut
        case unreadable

        var errorDescription: String? {
            switch self {
            case .challenged:
                return "DuckDuckGo asked for a human check instead of returning results. "
                    + "Wait a few minutes and try again, or choose a different search "
                    + "service in Settings → Chat."
            case .navigation(let reason):
                return "Couldn't reach DuckDuckGo: \(reason)"
            case .timedOut:
                return "DuckDuckGo didn't respond in time."
            case .unreadable:
                return "DuckDuckGo returned a page this version of Dictator couldn't read — "
                    + "the layout of its results may have changed."
            }
        }
    }

    // MARK: - Public

    func search(_ query: String, limit: Int) async throws -> [WebSearchResult] {
        if let hit = cached(query) { return hit }

        // One engine, one page at a time. A preempted chat round is simply
        // re-run (see ChatEngine), so two navigations can genuinely be asked
        // for at once; without this the second would cancel the first mid-load.
        await acquire()
        defer { release() }

        // Re-check: the search we were queued behind may have been this one.
        if let hit = cached(query) { return hit }

        guard var components = URLComponents(string: "https://lite.duckduckgo.com/lite/") else {
            throw SearchError.unreadable
        }
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else { throw SearchError.unreadable }

        let page = engine()
        try await load(url, in: page)

        let results = try await extract(from: page, limit: limit)
        remember(query: query, results: results)
        scheduleTeardown()
        return results
    }

    /// Drops the engine now. Called when web search is switched off or the
    /// backend changes, so a WebContent process isn't left resident for a
    /// feature the user has just turned off.
    func shutDown() {
        teardownTask?.cancel()
        teardownTask = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        navigator = nil
        cache.removeAll()
    }

    // MARK: - The engine

    private var webView: WKWebView?
    private var navigator: Navigator?
    private var teardownTask: Task<Void, Never>?

    /// A WebContent process costs about a second to start, so it's kept
    /// between searches — and dropped after a spell of quiet, because a chat
    /// the user has walked away from shouldn't hold one open. Created lazily
    /// on the first search rather than at launch: this app has a documented
    /// history of main-thread stalls on the hotkey path, and starting a
    /// browser engine is not something to do next to a microphone.
    private func engine() -> WKWebView {
        teardownTask?.cancel()
        teardownTask = nil
        if let existing = webView { return existing }

        let configuration = WKWebViewConfiguration()
        // Nothing persists: no cookies, no cache, no history carried between
        // launches. Each run of the app is a fresh visitor.
        configuration.websiteDataStore = .nonPersistent()
        let page = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: configuration)
        let delegate = Navigator()
        page.navigationDelegate = delegate
        webView = page
        navigator = delegate
        return page
    }

    private func scheduleTeardown() {
        teardownTask?.cancel()
        teardownTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled else { return }
            self?.shutDown()
        }
    }

    // MARK: - Navigation

    /// Bridges `WKNavigationDelegate` callbacks to one continuation.
    ///
    /// `finish` is cleared *before* it's called, everywhere, so a page that
    /// reports both a failure and a finish — or a timeout racing a real
    /// completion — can't resume the same continuation twice and trap.
    private final class Navigator: NSObject, WKNavigationDelegate {
        var finish: ((Result<Void, Error>) -> Void)?

        private func complete(_ result: Result<Void, Error>) {
            let handler = finish
            finish = nil
            handler?(result)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            complete(.success(()))
        }

        func webView(
            _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
        ) {
            complete(.failure(SearchError.navigation(error.localizedDescription)))
        }

        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            complete(.failure(SearchError.navigation(error.localizedDescription)))
        }
    }

    /// Loads the page, with a watchdog rather than a task group.
    ///
    /// The obvious `withThrowingTaskGroup` race doesn't compile under Swift 6's
    /// region-based isolation checker once the operation is a generic
    /// `@MainActor` closure. This is simpler anyway: on expiry it stops the
    /// load and fails the pending continuation directly, so there is exactly
    /// one thing that can resume it and no window where a timed-out navigation
    /// is left hanging.
    private func load(_ url: URL, in page: WKWebView) async throws {
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.navigationTimeout))
            guard !Task.isCancelled, let self else { return }
            self.webView?.stopLoading()
            self.failPendingNavigation(with: SearchError.timedOut)
        }
        defer { watchdog.cancel() }
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            navigator?.finish = { continuation.resume(with: $0) }
            page.load(URLRequest(url: url))
        }
    }

    private static let navigationTimeout: Double = 20

    /// Resumes a navigation continuation the timeout abandoned, so it can't be
    /// left pending forever.
    private func failPendingNavigation(with error: Error) {
        guard let navigator, let handler = navigator.finish else { return }
        navigator.finish = nil
        handler(.failure(error))
    }

    // MARK: - Extraction

    private func extract(from page: WKWebView, limit: Int) async throws -> [WebSearchResult] {
        for attempt in 0..<12 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(100)) }
            guard let raw = try? await page.evaluateJavaScript(Self.extractionJS) as? String,
                  let data = raw.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if payload["anomaly"] as? Bool == true { throw SearchError.challenged }

            let rows = payload["results"] as? [[String: Any]] ?? []
            if rows.isEmpty { continue }
            return rows.prefix(limit).map { row in
                WebSearchResult(
                    title: row["title"] as? String ?? "",
                    url: row["url"] as? String ?? "",
                    snippet: row["snippet"] as? String ?? ""
                )
            }
        }
        // Twelve empty reads of a page that loaded: either DuckDuckGo changed
        // its markup, or this query genuinely has no results. Both are
        // "nothing to show", and the caller says so honestly.
        return []
    }

    /// Walks result rows structurally rather than by index.
    ///
    /// The lite page is a table of four-row groups — spacer, link, snippet,
    /// displayed-address — so the snippet for a link is in its row's *next
    /// sibling*. Zipping two flat `querySelectorAll` lists together looks
    /// equivalent and isn't: an advert contributes an extra link and no
    /// matching snippet, which shifts every pairing after it by one.
    private static let extractionJS = #"""
    (() => {
      const isEngineOwned = (href) => {
        try {
          const host = new URL(href).hostname.toLowerCase();
          return host === 'duckduckgo.com' || host.endsWith('.duckduckgo.com');
        } catch (e) {
          return true;
        }
      };
      const out = [];
      for (const anchor of document.querySelectorAll('a.result-link')) {
        const href = anchor.href;
        if (!href || !/^https?:/i.test(href) || isEngineOwned(href)) continue;
        const row = anchor.closest('tr');
        let snippet = '';
        if (row) {
          const next = row.nextElementSibling;
          const cell = next && next.querySelector('td.result-snippet');
          if (cell) snippet = cell.innerText.trim();
        }
        out.push({ title: anchor.textContent.trim(), url: href, snippet: snippet });
        if (out.length >= 12) break;
      }
      return JSON.stringify({
        anomaly: !!document.querySelector(
          '[data-testid=anomaly-modal], #challenge-form, form[action*=challenge]'),
        results: out
      });
    })()
    """#

    // MARK: - Serialisation

    private var isBusy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        while isBusy {
            await withCheckedContinuation { waiting.append($0) }
        }
        isBusy = true
    }

    private func release() {
        isBusy = false
        guard !waiting.isEmpty else { return }
        waiting.removeFirst().resume()
    }

    // MARK: - Cache

    /// A short memory of recent searches.
    ///
    /// Not a speed optimisation. A chat round runs at `LLMScheduler.background`
    /// and is re-run whole when dictation preempts it, so the same search can
    /// legitimately be asked for several times in a minute — and hammering
    /// DuckDuckGo is precisely what earns the challenge page.
    private struct Entry {
        let query: String
        let results: [WebSearchResult]
        let at: Date
    }

    private var cache: [Entry] = []
    private static let cacheLifetime: TimeInterval = 300
    private static let cacheSize = 8

    private func cached(_ query: String) -> [WebSearchResult]? {
        let key = query.lowercased()
        cache.removeAll { Date().timeIntervalSince($0.at) > Self.cacheLifetime }
        return cache.first { $0.query == key }?.results
    }

    private func remember(query: String, results: [WebSearchResult]) {
        guard !results.isEmpty else { return }
        let key = query.lowercased()
        cache.removeAll { $0.query == key }
        cache.append(Entry(query: key, results: results, at: Date()))
        if cache.count > Self.cacheSize { cache.removeFirst(cache.count - Self.cacheSize) }
    }
}
