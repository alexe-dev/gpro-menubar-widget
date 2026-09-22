import Cocoa

let symbol = ProcessInfo.processInfo.environment["TICKER"] ?? "GPRO"
let refreshInterval: TimeInterval = Double(ProcessInfo.processInfo.environment["REFRESH"] ?? "") ?? 5

enum Session: String {
    case pre = "PRE", regular = "", post = "POST", closed = "CLOSED"
}

struct Quote {
    let price: Double          // last trade, extended hours included
    let changePercent: Double  // against the current session's base
    let change: Double
    let session: Session
    let regularPrice: Double
    let previousClose: Double
    let name: String
    let currency: String
    let dayLow: Double
    let dayHigh: Double
    let weekLow: Double
    let weekHigh: Double
    let tickTime: Date
}

struct NewsItem {
    let title: String
    let publisher: String
    let link: String
    let published: Date
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var timer: Timer?
    let priceItem = NSMenuItem(title: "Загрузка…", action: nil, keyEquivalent: "")
    let sessionItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let regularItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let rangeItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let updatedItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    var inFlight = false
    var newsTimer: Timer?
    let newsHeader = NSMenuItem(title: "Новости", action: nil, keyEquivalent: "")
    var newsItems: [NSMenuItem] = []
    let newsCount = 3

    func applicationDidFinishLaunching(_ notification: Notification) {
        item.button?.title = "\(symbol) …"
        priceItem.attributedTitle = NSAttributedString(
            string: "Загрузка…",
            attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor])

        let menu = NSMenu()
        menu.autoenablesItems = false
        [priceItem, sessionItem, regularItem, rangeItem, updatedItem].forEach {
            $0.isEnabled = true
            menu.addItem($0)
        }
        menu.addItem(.separator())
        newsHeader.isEnabled = true
        newsHeader.attributedTitle = styled("Новости", size: 11, weight: .semibold, color: .secondaryLabelColor)
        menu.addItem(newsHeader)
        for _ in 0..<newsCount {
            let entry = NSMenuItem(title: "", action: #selector(openNews(_:)), keyEquivalent: "")
            entry.target = self
            entry.isEnabled = true
            entry.isHidden = true
            newsItems.append(entry)
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let refreshItem = NSMenuItem(title: "Обновить сейчас", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        let webItem = NSMenuItem(title: "Открыть на Yahoo Finance", action: #selector(openWeb), keyEquivalent: "o")
        webItem.target = self
        menu.addItem(webItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Выход", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)
        item.menu = menu

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer?.tolerance = refreshInterval / 5

        // News changes rarely, so it gets its own 5-minute timer instead of hammering the endpoint.
        refreshNews()
        newsTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refreshNews()
        }
        newsTimer?.tolerance = 30
    }

    @objc func openWeb() {
        NSWorkspace.shared.open(URL(string: "https://finance.yahoo.com/quote/\(symbol)")!)
    }

    @objc func openNews(_ sender: NSMenuItem) {
        if let link = sender.representedObject as? String, let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
    }

    func refreshNews() {
        let url = URL(string: "https://query1.finance.yahoo.com/v1/finance/search?q=\(symbol)&newsCount=\(newsCount)&quotesCount=0")!
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard
                let data = data,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let raw = json["news"] as? [[String: Any]]
            else { return }
            let items = raw.compactMap { entry -> NewsItem? in
                guard let title = entry["title"] as? String,
                      let link = entry["link"] as? String else { return nil }
                return NewsItem(
                    title: title,
                    publisher: entry["publisher"] as? String ?? "",
                    link: link,
                    published: Date(timeIntervalSince1970: entry["providerPublishTime"] as? Double ?? 0))
            }
            DispatchQueue.main.async { self?.renderNews(items) }
        }.resume()
    }

    func renderNews(_ items: [NewsItem]) {
        newsHeader.isHidden = items.isEmpty
        for (index, entry) in newsItems.enumerated() {
            guard index < items.count else {
                entry.isHidden = true
                continue
            }
            let news = items[index]
            entry.isHidden = false
            entry.representedObject = news.link

            // Headlines can be long; trim on a word boundary so the menu keeps its width.
            var headline = news.title
            if headline.count > 64 {
                headline = String(headline.prefix(64)).split(separator: " ").dropLast().joined(separator: " ") + "…"
            }
            let line = NSMutableAttributedString()
            line.append(styled(headline, size: 12, weight: .medium))
            line.append(styled("\n\(news.publisher) · \(relative(news.published))",
                               size: 10, color: .secondaryLabelColor))
            entry.attributedTitle = line
        }
    }

    func relative(_ date: Date) -> String {
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        if minutes < 1 { return "только что" }
        if minutes < 60 { return "\(minutes) мин назад" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) ч назад" }
        return "\(hours / 24) дн назад"
    }

    @objc func refresh() {
        guard !inFlight else { return }
        inFlight = true
        fetch { [weak self] quote in
            DispatchQueue.main.async {
                self?.inFlight = false
                self?.render(quote)
            }
        }
    }

    // macOS dims disabled menu items on top of any color, so we style attributedTitle ourselves.
    func styled(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                color: NSColor = .labelColor, mono: Bool = false) -> NSAttributedString {
        let font = mono
            ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    }

    // An SF Symbol as a text attachment: inline with the text, with its own color.
    func icon(_ name: String, color: NSColor, size: CGFloat) -> NSAttributedString {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
            .applying(.init(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return NSAttributedString(string: "") }
        let attachment = NSTextAttachment()
        attachment.image = image
        return NSAttributedString(attachment: attachment)
    }

    func sessionIcon(_ session: Session) -> (symbol: String, color: NSColor) {
        switch session {
        case .pre: return ("sunrise.fill", NSColor(srgbRed: 0.83, green: 0.44, blue: 0.20, alpha: 1))
        case .regular: return ("sun.max.fill", NSColor(srgbRed: 0.80, green: 0.60, blue: 0.10, alpha: 1))
        case .post: return ("sunset.fill", NSColor(srgbRed: 0.45, green: 0.36, blue: 0.72, alpha: 1))
        case .closed: return ("moon.fill", NSColor.secondaryLabelColor)
        }
    }

    func render(_ quote: Quote?) {
        guard let q = quote else {
            updatedItem.attributedTitle = styled("Ошибка загрузки · повтор через \(Int(refreshInterval)) с",
                                                 size: 11, color: .systemRed)
            return
        }
        let up = q.changePercent >= 0
        // Muted shades: the system green/red are too loud on a light menu bar,
        // while dark mode needs them lighter so they don't sink into the background.
        let accent = NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            if up {
                return dark ? NSColor(srgbRed: 0.28, green: 0.72, blue: 0.42, alpha: 1)
                            : NSColor(srgbRed: 0.10, green: 0.45, blue: 0.24, alpha: 1)
            }
            return dark ? NSColor(srgbRed: 0.92, green: 0.40, blue: 0.38, alpha: 1)
                        : NSColor(srgbRed: 0.62, green: 0.14, blue: 0.13, alpha: 1)
        }
        let arrow = up ? "▲" : "▼"

        // Title: price, colored percentage and a small session mark — the ticker lives in the menu.
        let title = NSMutableAttributedString()
        title.append(styled(String(format: "%.2f  ", q.price), size: 13, weight: .semibold, mono: true))
        title.append(styled(String(format: "%@%.2f%%", arrow, abs(q.changePercent)),
                            size: 12, weight: .semibold, color: accent, mono: true))
        let mark = sessionIcon(q.session)
        title.append(NSAttributedString(string: "  "))
        title.append(icon(mark.symbol, color: mark.color, size: 10))
        item.button?.attributedTitle = title

        let headline = NSMutableAttributedString()
        headline.append(styled(String(format: "%.4f %@", q.price, q.currency), size: 17, weight: .semibold, mono: true))
        headline.append(styled(String(format: "   %@%.4f  (%+.2f%%)", arrow, abs(q.change), q.changePercent),
                               size: 13, weight: .medium, color: accent, mono: true))
        priceItem.attributedTitle = headline

        let sessionName: String
        switch q.session {
        case .pre: sessionName = "Пре-маркет"
        case .regular: sessionName = "Основные торги"
        case .post: sessionName = "Пост-маркет"
        case .closed: sessionName = "Рынок закрыт"
        }
        let sessionLine = NSMutableAttributedString()
        sessionLine.append(icon(mark.symbol, color: mark.color, size: 11))
        sessionLine.append(styled("  \(sessionName)  ·  \(q.name)", size: 12, weight: .semibold))
        sessionItem.attributedTitle = sessionLine

        // During regular hours regularMarketPrice is the live price rather than a close,
        // and the base shifts: extended hours count from the close, regular hours from the previous close.
        let extended = q.session == .pre || q.session == .post
        let regularLabel = extended ? "Закрытие осн." : "Осн. сессия"
        let baseMark = "◂ база"
        let baseColor = NSColor.secondaryLabelColor
        let baseLine = NSMutableAttributedString()
        baseLine.append(styled(String(format: "%@  %.2f", regularLabel, q.regularPrice),
                               size: 12, weight: extended ? .semibold : .medium, mono: true))
        if extended { baseLine.append(styled(" " + baseMark, size: 10, color: baseColor)) }
        baseLine.append(styled("          ", size: 12, mono: true))
        baseLine.append(styled(String(format: "Пред. закрытие  %.2f", q.previousClose),
                               size: 12, weight: extended ? .medium : .semibold, mono: true))
        if !extended { baseLine.append(styled(" " + baseMark, size: 10, color: baseColor)) }
        regularItem.attributedTitle = baseLine

        rangeItem.attributedTitle = styled(
            String(format: "День  %.2f – %.2f          52 нед  %.2f – %.2f",
                   q.dayLow, q.dayHigh, q.weekLow, q.weekHigh),
            size: 12, weight: .medium, mono: true)

        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        updatedItem.attributedTitle = styled(
            "Тик \(fmt.string(from: q.tickTime))   ·   опрос \(fmt.string(from: Date()))",
            size: 11, color: .secondaryLabelColor, mono: true)
    }

    func fetch(_ completion: @escaping (Quote?) -> Void) {
        let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(symbol)?interval=1m&range=1d&includePrePost=true")!
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        req.timeoutInterval = 10
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard
                let data = data,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let chart = json["chart"] as? [String: Any],
                let result = (chart["result"] as? [[String: Any]])?.first,
                let meta = result["meta"] as? [String: Any],
                let regularPrice = meta["regularMarketPrice"] as? Double
            else { return completion(nil) }

            let previousClose = (meta["chartPreviousClose"] as? Double)
                ?? (meta["previousClose"] as? Double) ?? regularPrice

            // The last non-null tick of the minute series is the pre/post-market price.
            var lastPrice = regularPrice
            var lastStamp = (meta["regularMarketTime"] as? Double) ?? Date().timeIntervalSince1970
            if let stamps = result["timestamp"] as? [Double],
               let quotes = (result["indicators"] as? [String: Any])?["quote"] as? [[String: Any]],
               let closes = quotes.first?["close"] as? [Double?] {
                for (stamp, close) in zip(stamps, closes).reversed() {
                    if let close = close {
                        lastPrice = close
                        lastStamp = stamp
                        break
                    }
                }
            }

            // The session follows from where the last tick falls in Yahoo's trading periods.
            var session = Session.closed
            if let periods = meta["currentTradingPeriod"] as? [String: Any] {
                func inside(_ key: String) -> Bool {
                    guard let p = periods[key] as? [String: Any],
                          let start = p["start"] as? Double, let end = p["end"] as? Double
                    else { return false }
                    return lastStamp >= start && lastStamp < end
                }
                if inside("regular") { session = .regular }
                else if inside("pre") { session = .pre }
                else if inside("post") { session = .post }
            }

            // In extended sessions the change is measured against the regular session close.
            let base = (session == .pre || session == .post) ? regularPrice : previousClose
            let change = lastPrice - base
            let changePercent = base == 0 ? 0 : change / base * 100

            completion(Quote(
                price: lastPrice,
                changePercent: changePercent,
                change: change,
                session: session,
                regularPrice: regularPrice,
                previousClose: previousClose,
                name: meta["longName"] as? String ?? symbol,
                currency: meta["currency"] as? String ?? "",
                dayLow: meta["regularMarketDayLow"] as? Double ?? 0,
                dayHigh: meta["regularMarketDayHigh"] as? Double ?? 0,
                weekLow: meta["fiftyTwoWeekLow"] as? Double ?? 0,
                weekHigh: meta["fiftyTwoWeekHigh"] as? Double ?? 0,
                tickTime: Date(timeIntervalSince1970: lastStamp)))
        }.resume()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
