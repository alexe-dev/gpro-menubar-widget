import Cocoa
import Network

// Symbol resolution: saved choice → TICKER env var → GPRO.
var symbol: String {
    get {
        UserDefaults.standard.string(forKey: "ticker")
            ?? ProcessInfo.processInfo.environment["TICKER"]
            ?? "GPRO"
    }
    set { UserDefaults.standard.set(newValue.uppercased(), forKey: "ticker") }
}
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

struct Balance {
    let value: Double          // account value
    let currency: String
    let pnl: Double?
    let pnlPercent: Double?
    let margin: Double?
    let health: String?
    let cash: Double?
    let hidden: Bool
    let received: Date
}

/// Loopback HTTP endpoint the Chrome extension posts the Trading 212 balance to.
/// Bound to 127.0.0.1 only: nothing on the network can reach it.
final class BalanceServer {
    private var listener: NWListener?
    private let onUpdate: (Balance) -> Void

    init(onUpdate: @escaping (Balance) -> Void) {
        self.onUpdate = onUpdate
    }

    func start(port: UInt16) {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1",
                                                          port: NWEndpoint.Port(rawValue: port)!)
        guard let listener = try? NWListener(using: params) else {
            FileHandle.standardError.write("balance server: port \(port) unavailable\n".data(using: .utf8)!)
            return
        }
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        listener.start(queue: .global(qos: .utility))
        self.listener = listener
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .utility))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self = self, let data = data,
                  let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }

            // The content script runs on trading212.com, so preflight has to be answered.
            let cors = "Access-Control-Allow-Origin: *\r\n"
                + "Access-Control-Allow-Methods: POST, OPTIONS\r\n"
                + "Access-Control-Allow-Headers: Content-Type\r\n"
            if request.hasPrefix("OPTIONS") {
                self.reply(connection, "HTTP/1.1 204 No Content\r\n" + cors + "Content-Length: 0\r\n\r\n")
                return
            }

            guard let separator = request.range(of: "\r\n\r\n") else {
                connection.cancel()
                return
            }
            let body = String(request[separator.upperBound...])
            guard let payload = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let value = json["balance"] as? Double else {
                self.reply(connection, "HTTP/1.1 400 Bad Request\r\n" + cors + "Content-Length: 0\r\n\r\n")
                return
            }

            self.onUpdate(Balance(
                value: value,
                currency: json["currency"] as? String ?? "",
                pnl: json["pnl"] as? Double,
                pnlPercent: json["pnlPercent"] as? Double,
                margin: json["margin"] as? Double,
                health: json["health"] as? String,
                cash: json["cash"] as? Double,
                hidden: json["hidden"] as? Bool ?? false,
                received: Date()))
            self.reply(connection, "HTTP/1.1 200 OK\r\n" + cors + "Content-Length: 2\r\n\r\nok")
        }
    }

    // Closing the socket must wait for the response to actually be written.
    private func reply(_ connection: NWConnection, _ response: String) {
        connection.send(content: response.data(using: .utf8),
                        completion: .contentProcessed { _ in connection.cancel() })
    }
}

enum Lang: String {
    case ru, en

    static var current: Lang {
        get {
            if let saved = UserDefaults.standard.string(forKey: "language"), let lang = Lang(rawValue: saved) {
                return lang
            }
            return .en   // English is the default; the choice is remembered once made
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "language") }
    }
}

// key: (ru, en)
let strings: [String: (String, String)] = [
    "loading": ("Загрузка…", "Loading…"),
    "news": ("Новости", "News"),
    "refresh": ("Обновить сейчас", "Refresh now"),
    "openWeb": ("Открыть на Yahoo Finance", "Open on Yahoo Finance"),
    "language": ("Язык", "Language"),
    "symbol": ("Тикер: %@", "Symbol: %@"),
    "changeSymbol": ("Смена тикера", "Change symbol"),
    "changeSymbolInfo": ("Любой символ Yahoo Finance, например AAPL или BTC-USD.",
                         "Any Yahoo Finance symbol, for example AAPL or BTC-USD."),
    "ok": ("Готово", "OK"),
    "cancel": ("Отмена", "Cancel"),
    "balance": ("Счёт", "Account"),
    "margin": ("Маржа", "Margin"),
    "health": ("Health", "Health"),
    "cash": ("Кэш", "Cash"),
    "stale": ("данные устарели", "stale"),
    "background": ("вкладка в фоне", "tab in background"),
    "unknownSymbol": ("Не нашёл такой тикер — оставил %@", "No such symbol — keeping %@"),
    "quit": ("Выход", "Quit"),
    "error": ("Ошибка загрузки · повтор через %d с", "Fetch failed · retrying in %ds"),
    "pre": ("Пре-маркет", "Pre-market"),
    "regular": ("Основные торги", "Regular hours"),
    "post": ("Пост-маркет", "After hours"),
    "closed": ("Рынок закрыт", "Market closed"),
    "regularClose": ("Закрытие осн.", "Regular close"),
    "regularLive": ("Осн. сессия", "Regular session"),
    "prevClose": ("Пред. закрытие", "Previous close"),
    "base": ("◂ база", "◂ base"),
    "day": ("День", "Day"),
    "week52": ("52 нед", "52wk"),
    "tick": ("Тик", "Tick"),
    "poll": ("опрос", "poll"),
    "justNow": ("только что", "just now"),
    "minutesAgo": ("%d мин назад", "%dm ago"),
    "hoursAgo": ("%d ч назад", "%dh ago"),
    "daysAgo": ("%d дн назад", "%dd ago"),
]

enum GPROStrings {
    static func translate(_ key: String) -> String {
        guard let pair = strings[key] else { return key }
        return Lang.current == .ru ? pair.0 : pair.1
    }
}

func t(_ key: String) -> String { GPROStrings.translate(key) }

struct NewsItem {
    let title: String
    let publisher: String
    let link: String
    let published: Date
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var timer: Timer?
    let priceItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let sessionItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let regularItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let rangeItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let updatedItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    var inFlight = false
    var newsTimer: Timer?
    let newsHeader = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    var newsItems: [NSMenuItem] = []
    let newsCount = 3
    let languageItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    var symbolItem = NSMenuItem()
    let balanceItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    var balanceServer: BalanceServer?
    let balanceDetailItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    var balance: Balance?
    let balancePort: UInt16 = UInt16(ProcessInfo.processInfo.environment["BALANCE_PORT"] ?? "") ?? 47632
    var lastQuote: Quote?
    var refreshItem = NSMenuItem()
    var webItem = NSMenuItem()
    var quitItem = NSMenuItem()

    func applicationDidFinishLaunching(_ notification: Notification) {
        item.button?.title = "\(symbol) …"
        priceItem.attributedTitle = styled(t("loading"), size: 13, color: .secondaryLabelColor)

        let menu = NSMenu()
        menu.autoenablesItems = false
        [priceItem, sessionItem, regularItem, rangeItem, updatedItem].forEach {
            $0.isEnabled = true
            menu.addItem($0)
        }
        balanceItem.isEnabled = true
        balanceItem.isHidden = true
        menu.addItem(balanceItem)
        balanceDetailItem.isEnabled = true
        balanceDetailItem.isHidden = true
        menu.addItem(balanceDetailItem)

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
        symbolItem = NSMenuItem(title: "", action: #selector(changeSymbol), keyEquivalent: "s")
        symbolItem.target = self
        menu.addItem(symbolItem)
        refreshItem = NSMenuItem(title: "", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        webItem = NSMenuItem(title: "", action: #selector(openWeb), keyEquivalent: "o")
        webItem.target = self
        menu.addItem(webItem)

        let languageMenu = NSMenu()
        languageMenu.autoenablesItems = false
        for (lang, label) in [(Lang.ru, "Русский"), (Lang.en, "English")] {
            let option = NSMenuItem(title: label, action: #selector(switchLanguage(_:)), keyEquivalent: "")
            option.target = self
            option.isEnabled = true
            option.representedObject = lang.rawValue
            option.state = Lang.current == lang ? .on : .off
            languageMenu.addItem(option)
        }
        languageItem.submenu = languageMenu
        languageItem.isEnabled = true
        menu.addItem(languageItem)

        menu.addItem(.separator())
        quitItem = NSMenuItem(title: "", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)
        applyLanguage()
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

        // The Chrome extension pushes the Trading 212 balance here; the widget never scrapes anything itself.
        balanceServer = BalanceServer { [weak self] balance in
            DispatchQueue.main.async { self?.renderBalance(balance) }
        }
        balanceServer?.start(port: balancePort)
    }

    @objc func switchLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let lang = Lang(rawValue: raw) else { return }
        Lang.current = lang
        sender.menu?.items.forEach { $0.state = ($0.representedObject as? String) == raw ? .on : .off }
        applyLanguage()
        render(lastQuote)   // redraw what we already have instead of waiting for the next poll
        refreshNews()
    }

    // Static menu labels; dynamic lines are translated inside render/renderNews.
    func applyLanguage() {
        newsHeader.attributedTitle = styled(t("news"), size: 11, weight: .semibold, color: .secondaryLabelColor)
        symbolItem.title = String(format: t("symbol"), symbol)
        refreshItem.title = t("refresh")
        webItem.title = t("openWeb")
        languageItem.title = t("language")
        quitItem.title = t("quit")
        if lastQuote == nil {
            priceItem.attributedTitle = styled(t("loading"), size: 13, color: .secondaryLabelColor)
        }
    }

    @objc func changeSymbol() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = t("changeSymbol")
        alert.informativeText = t("changeSymbolInfo")
        alert.addButton(withTitle: t("ok"))
        alert.addButton(withTitle: t("cancel"))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = symbol
        field.placeholderString = "GPRO"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let entered = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !entered.isEmpty, entered != symbol else { return }

        // Keep the previous symbol until the new one actually resolves to a quote.
        let previous = symbol
        symbol = entered
        lastQuote = nil
        applyLanguage()
        item.button?.attributedTitle = styled("\(entered) …", size: 12, color: .secondaryLabelColor)
        fetch { [weak self] quote in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let quote = quote {
                    self.render(quote)
                    self.refreshNews()
                } else {
                    symbol = previous
                    self.applyLanguage()
                    let warning = NSAlert()
                    warning.messageText = String(format: self.t("unknownSymbol"), previous)
                    warning.runModal()
                    self.refresh()
                }
            }
        }
    }

    // Instance shim so the closure above can reach the global translator.
    func t(_ key: String) -> String { GPROStrings.translate(key) }

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

    func renderBalance(_ balance: Balance?) {
        if let balance = balance {
            self.balance = balance
            render(lastQuote)   // the menu bar title carries the account total too
        }
        guard let account = self.balance else {
            balanceItem.isHidden = true
            balanceDetailItem.isHidden = true
            return
        }
        balanceItem.isHidden = false
        balanceDetailItem.isHidden = false

        // A tab that stopped updating is worse than no number, so age is always shown.
        let stale = Date().timeIntervalSince(account.received) > 90
        let primary: NSColor = stale ? .secondaryLabelColor : .labelColor

        let line = NSMutableAttributedString()
        line.append(icon("wallet.bifold.fill", color: .secondaryLabelColor, size: 11))
        line.append(styled(String(format: "  %@  %@ %@", t("balance"), grouped(account.value), account.currency),
                           size: 13, weight: .semibold, color: primary, mono: true))
        if let pnl = account.pnl {
            let positive = pnl >= 0
            let color: NSColor = stale
                ? .secondaryLabelColor
                : (positive ? NSColor(srgbRed: 0.10, green: 0.45, blue: 0.24, alpha: 1)
                            : NSColor(srgbRed: 0.72, green: 0.20, blue: 0.18, alpha: 1))
            var text = String(format: "   %@%@", positive ? "+" : "−", grouped(abs(pnl)))
            if let percent = account.pnlPercent {
                text += String(format: "  (%.2f%%)", abs(percent))
            }
            line.append(styled(text, size: 12, weight: .medium, color: color, mono: true))
        }
        balanceItem.attributedTitle = line

        var parts: [String] = []
        if let margin = account.margin { parts.append("\(t("margin"))  \(grouped(margin))") }
        if let health = account.health { parts.append("\(t("health"))  \(health)") }
        if let cash = account.cash { parts.append("\(t("cash"))  \(grouped(cash))") }
        let detail = NSMutableAttributedString()
        detail.append(styled(parts.joined(separator: "     ·     "),
                             size: 12, weight: .medium, color: .secondaryLabelColor, mono: true))
        var note = relative(account.received)
        if account.hidden { note += " · " + t("background") }
        if stale { note += " · " + t("stale") }
        detail.append(styled("   " + note, size: 10,
                             color: (stale || account.hidden) ? .systemOrange : .tertiaryLabelColor))
        balanceDetailItem.attributedTitle = detail
    }

    func grouped(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = " "
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    func relative(_ date: Date) -> String {
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        if minutes < 1 { return t("justNow") }
        if minutes < 60 { return String(format: t("minutesAgo"), minutes) }
        let hours = minutes / 60
        if hours < 24 { return String(format: t("hoursAgo"), hours) }
        return String(format: t("daysAgo"), hours / 24)
    }

    @objc func refresh() {
        guard !inFlight else { return }
        inFlight = true
        fetch { [weak self] quote in
            DispatchQueue.main.async {
                self?.inFlight = false
                self?.render(quote)
                self?.renderBalance(nil)
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
            updatedItem.attributedTitle = styled(String(format: t("error"), Int(refreshInterval)),
                                                 size: 11, color: .systemRed)
            return
        }
        lastQuote = q
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
        // The account total rides along after the session mark: same weight as the price
        // so it reads as a second figure, with a small "k" that stays out of the way.
        // Age is flagged with a mark rather than by dimming — a number worth showing is
        // worth showing legibly.
        if let account = balance {
            title.append(NSAttributedString(string: "  "))
            title.append(styled(String(format: "%.0f", account.value / 1000),
                                size: 13, weight: .semibold, mono: true))
            title.append(styled("k", size: 10, weight: .medium, color: .secondaryLabelColor))

            // Health is the number that matters when it drops, so it is colored by level.
            if let health = account.health {
                let level = Double(health.filter("0123456789.".contains)) ?? 100
                let color: NSColor = level < 20
                    ? NSColor(srgbRed: 0.72, green: 0.20, blue: 0.18, alpha: 1)
                    : level < 40 ? NSColor(srgbRed: 0.72, green: 0.44, blue: 0.05, alpha: 1)
                    : .labelColor
                title.append(NSAttributedString(string: "  "))
                title.append(icon("heart.fill", color: color, size: 9))
                title.append(styled(" " + health, size: 12, weight: .semibold, color: color, mono: true))
            }

            let ageing = Date().timeIntervalSince(account.received) > 90
            if ageing || account.hidden {
                title.append(NSAttributedString(string: " "))
                title.append(icon(ageing ? "clock.badge.exclamationmark.fill" : "zzz",
                                  color: .systemOrange, size: 9))
            }
        }
        item.button?.attributedTitle = title

        let headline = NSMutableAttributedString()
        headline.append(styled(String(format: "%.4f %@", q.price, q.currency), size: 17, weight: .semibold, mono: true))
        headline.append(styled(String(format: "   %@%.4f  (%+.2f%%)", arrow, abs(q.change), q.changePercent),
                               size: 13, weight: .medium, color: accent, mono: true))
        priceItem.attributedTitle = headline

        let sessionName: String
        switch q.session {
        case .pre: sessionName = t("pre")
        case .regular: sessionName = t("regular")
        case .post: sessionName = t("post")
        case .closed: sessionName = t("closed")
        }
        let sessionLine = NSMutableAttributedString()
        sessionLine.append(icon(mark.symbol, color: mark.color, size: 11))
        sessionLine.append(styled("  \(sessionName)  ·  \(q.name)", size: 12, weight: .semibold))
        sessionItem.attributedTitle = sessionLine

        // During regular hours regularMarketPrice is the live price rather than a close,
        // and the base shifts: extended hours count from the close, regular hours from the previous close.
        let extended = q.session == .pre || q.session == .post
        let regularLabel = extended ? t("regularClose") : t("regularLive")
        let baseMark = t("base")
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
            String(format: "\(t("day"))  %.2f – %.2f          \(t("week52"))  %.2f – %.2f",
                   q.dayLow, q.dayHigh, q.weekLow, q.weekHigh),
            size: 12, weight: .medium, mono: true)

        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        updatedItem.attributedTitle = styled(
            "\(t("tick")) \(fmt.string(from: q.tickTime))   ·   \(t("poll")) \(fmt.string(from: Date()))",
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
