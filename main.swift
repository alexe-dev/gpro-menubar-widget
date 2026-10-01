import Cocoa
import Network
import SwiftUI

// Symbol resolution: saved choice → TICKER env var → GPRO.
var symbol: String {
    get {
        UserDefaults.standard.string(forKey: "ticker")
            ?? ProcessInfo.processInfo.environment["TICKER"]
            ?? "GPRO"
    }
    set { UserDefaults.standard.set(newValue.uppercased(), forKey: "ticker") }
}
// The secondary symbol shares the same resolution order, with its own saved key.
var symbol2: String {
    get {
        UserDefaults.standard.string(forKey: "ticker2")
            ?? ProcessInfo.processInfo.environment["TICKER2"]
            ?? "KOD"
    }
    set { UserDefaults.standard.set(newValue.uppercased(), forKey: "ticker2") }
}
// Percentages in the menu bar are off by default: the prices are what gets glanced at.
var showPercent: Bool {
    get { UserDefaults.standard.bool(forKey: "showPercent") }
    set { UserDefaults.standard.set(newValue, forKey: "showPercent") }
}
// Take-profit targets per symbol, entered as the price a position would close at —
// the bid for a long, which is what Trading 212's own TP order takes.
var takeProfit: [String: Double] {
    get { UserDefaults.standard.dictionary(forKey: "takeProfit") as? [String: Double] ?? [:] }
    set { UserDefaults.standard.set(newValue, forKey: "takeProfit") }
}

// Money in and out, entered by hand from the platform's History screen: a CFD export
// does not see funds moved in from the Invest side, so it cannot answer this.
var depositsTotal: Double {
    get { UserDefaults.standard.double(forKey: "depositsTotal") }
    set { UserDefaults.standard.set(newValue, forKey: "depositsTotal") }
}

var withdrawalsTotal: Double {
    get { UserDefaults.standard.double(forKey: "withdrawalsTotal") }
    set { UserDefaults.standard.set(newValue, forKey: "withdrawalsTotal") }
}

var netDeposits: Double { depositsTotal - withdrawalsTotal }

/// Optional third symbol: empty means the block is not shown at all.
var symbol3: String {
    get { UserDefaults.standard.string(forKey: "ticker3") ?? "" }
    set { UserDefaults.standard.set(newValue.uppercased(), forKey: "ticker3") }
}

/// Deriving the account from the export and Yahoo prices is opt-in. By default the widget
/// only reports what the open Trading 212 tab tells it.
var computeFromExport: Bool {
    get { UserDefaults.standard.bool(forKey: "computeFromExport") }
    set { UserDefaults.standard.set(newValue, forKey: "computeFromExport") }
}

/// Which pieces the menu bar carries. Space up there is shared with every other app,
/// so each one can be dropped on its own.
enum TitlePart: String, CaseIterable {
    case first = "showFirst", second = "showSecond", third = "showThird"
    case health = "showHealth", total = "showTotal"

    var isOn: Bool {
        get { UserDefaults.standard.object(forKey: rawValue) as? Bool ?? true }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: rawValue) }
    }
}

let fxFeeRate = 0.005   // Trading 212 charges 0.5% of the result as an FX fee
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

struct Position {
    let symbol: String
    let direction: String     // Buy / Sell
    let units: Double
    let avgPrice: Double
    let currency: String
    let leverage: Double
    let spread: Double        // platform bid/ask width, in instrument currency
    let lots: Int

    var sign: Double { direction.lowercased() == "sell" ? -1 : 1 }

    /// A long is closed at the bid and margined at the ask; Yahoo's last trade sits near the mid.
    func closingPrice(from last: Double) -> Double { last - sign * spread / 2 }
    func marginPrice(from last: Double) -> Double { last + sign * spread / 2 }
}

/// Positions exported from Trading 212 (tools/t212-positions.py), plus the cash the
/// account had aside from open-position P/L.
struct Portfolio {
    let accountCurrency: String
    let cashFallback: Double
    let positions: [Position]
    let generated: String

    static func load() -> Portfolio? {
        // Run from a bundle, from a build directory or from launchd, the file sits in a
        // different place relative to the executable each time, so all of them are tried.
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let candidates: [String] = ([
            UserDefaults.standard.string(forKey: "positionsPath"),
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("positions.json").path,
            executable.deletingLastPathComponent().appendingPathComponent("positions.json").path(percentEncoded: false),
            // …/GPRO.app/Contents/MacOS/GPRO → …/positions.json
            executable.deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("positions.json").path(percentEncoded: false),
            NSHomeDirectory() + "/.config/gpro-widget/positions.json",
        ] as [String?]).compactMap { $0 }

        guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            FileHandle.standardError.write(
                "positions: not found, tried \(candidates.joined(separator: ", "))\n".data(using: .utf8)!)
            return nil
        }
        FileHandle.standardError.write("positions: \(path)\n".data(using: .utf8)!)

        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["positions"] as? [[String: Any]] else { return nil }

        let positions = raw.compactMap { entry -> Position? in
            guard let symbol = entry["symbol"] as? String,
                  let units = entry["units"] as? Double,
                  let avgPrice = entry["avgPrice"] as? Double else { return nil }
            return Position(
                symbol: symbol,
                direction: entry["direction"] as? String ?? "Buy",
                units: units,
                avgPrice: avgPrice,
                currency: entry["currency"] as? String ?? "USD",
                leverage: entry["leverage"] as? Double ?? 5,
                spread: entry["spread"] as? Double ?? 0,
                lots: entry["lots"] as? Int ?? 1)
        }
        guard !positions.isEmpty else { return nil }

        return Portfolio(
            accountCurrency: json["accountCurrency"] as? String ?? "CZK",
            cashFallback: json["cashFallback"] as? Double ?? 0,
            positions: positions,
            generated: json["generated"] as? String ?? "")
    }
}

/// What the account looks like at a given set of prices — the same arithmetic Trading 212
/// applies, so the figures keep moving when its own platform is closed for the night.
struct Holding {
    let symbol: String
    let lots: Int
    let result: Double
    let value: Double
    let margin: Double
}

/// The account as it would stand if every target were hit.
struct Scenario {
    let equity: Double
    let result: Double
    let margin: Double
    let health: Double
    let freeFunds: Double
    let holdings: [Holding]
    let covered: Int          // positions with a target set
}

struct Computed {
    let unrealized: Double
    let equity: Double
    let notional: Double
    let margin: Double
    let health: Double
    let freeFunds: Double
    let priced: Int          // positions we had a price for
    let total: Int
    let holdings: [Holding]
    let scenario: Scenario?
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
    private var lastLogged = Date.distantPast
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

            // A heartbeat line once a minute: enough to tell a silent bridge from a widget
            // that failed to render, without the log growing on every five-second tick.
            if Date().timeIntervalSince(self.lastLogged) > 60 {
                self.lastLogged = Date()
                FileHandle.standardError.write(
                    "balance: \(value) \(json["currency"] as? String ?? "") hidden=\(json["hidden"] as? Bool ?? false) at \(Date())\n"
                        .data(using: .utf8)!)
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
    "symbol2": ("Второй тикер: %@", "Second symbol: %@"),
    "symbol3": ("Третий тикер: %@", "Third symbol: %@"),
    "none": ("—", "—"),
    "computeToggle": ("Считать счёт по ценам Yahoo", "Compute account from Yahoo prices"),
    "showPercent": ("Проценты в меню-баре", "Percentages in the menu bar"),
    "changeSymbol": ("Смена тикера", "Change symbol"),
    "changeSymbolInfo": ("Любой символ Yahoo Finance, например AAPL или BTC-USD.",
                         "Any Yahoo Finance symbol, for example AAPL or BTC-USD."),
    "ok": ("Готово", "OK"),
    "cancel": ("Отмена", "Cancel"),
    "balance": ("Счёт", "Account"),
    "margin": ("Маржа", "Margin"),
    "health": ("Health", "Health"),
    "cash": ("Кэш", "Cash"),
    "value": ("Стоимость", "Value"),
    "result": ("Результат", "Result"),
    "lots": ("поз.", "pos."),
    "tp": ("Цели (TP)", "Targets (TP)"),
    "dashboard": ("Окно счёта", "Dashboard"),
    "tpSetTitle": ("Цены целей", "Target prices"),
    "tpSetInfo": ("Цена закрытия позиции: для лонга это bid. Пусто — без цели.",
                  "The price a position closes at — the bid for a long. Empty means no target."),
    "atTarget": ("При целях", "At targets"),
    "upside": ("к текущему", "vs now"),
    "invested": ("Внесено", "Net in"),
    "lifetime": ("Итого", "Overall"),
    "setDeposits": ("Депозиты и выводы", "Deposits and withdrawals"),
    "setDepositsInfo": ("Суммы с экрана History. Экспорт CFD их не знает: переводы с Invest в нём не видны.",
                        "The totals from the History screen. A CFD export cannot see funds moved in from Invest."),
    "deposits": ("Депозиты", "Deposits"),
    "withdrawals": ("Выводы", "Withdrawals"),
    "stale": ("данные устарели", "stale"),
    "background": ("вкладка в фоне", "tab in background"),
    "free": ("Свободно", "Free funds"),
    "computed": ("по ценам Yahoo", "from Yahoo prices"),
    "platform": ("T212", "T212"),
    "noPositions": ("positions.json не найден", "positions.json not found"),
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
    var quotePriceItems: [NSMenuItem] = []
    var quoteNameItems: [NSMenuItem] = []
    var quoteStatsItems: [NSMenuItem] = []
    let updatedItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    var inFlight = false
    var newsTimer: Timer?
    let newsHeader = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    var newsItems: [NSMenuItem] = []
    let newsCount = 1   // one headline per symbol, the latest
    let newsHeader2 = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let newsHeader3 = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    var newsItems3: [NSMenuItem] = []
    var newsItems2: [NSMenuItem] = []
    let languageItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    var symbolItem = NSMenuItem()
    let balanceItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    var balanceServer: BalanceServer?
    let balanceDetailItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    var balance: Balance?
    var portfolio: Portfolio?
    var priceCache: [String: Double] = [:]
    var fxCache: [String: Double] = [:]
    var computed: Computed?
    var lastComputeLog = Date.distantPast
    var holdingItems: [NSMenuItem] = []
    let holdingSlots = 4
    let tpHeader = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    var tpItems: [NSMenuItem] = []
    let tpTotalItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    var tpMenuItem = NSMenuItem()
    var depositsItem = NSMenuItem()
    var dashboardItem = NSMenuItem()
    var dashboardWindow: NSWindow?
    let lifetimeItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let balancePort: UInt16 = UInt16(ProcessInfo.processInfo.environment["BALANCE_PORT"] ?? "") ?? 47632
    var lastQuote: Quote?
    var lastQuote2: Quote?
    var lastQuote3: Quote?
    var symbolItem3 = NSMenuItem()
    var computeItem = NSMenuItem()
    var symbolItem2 = NSMenuItem()
    var percentItem = NSMenuItem()
    var refreshItem = NSMenuItem()
    var webItem = NSMenuItem()
    var quitItem = NSMenuItem()

    func applicationDidFinishLaunching(_ notification: Notification) {
        item.button?.title = "\(symbol) …"

        let menu = NSMenu()
        menu.autoenablesItems = false
        for slot in 0..<3 {
            let action: Selector = slot == 0 ? #selector(openWeb)
                : slot == 1 ? #selector(openWeb2) : #selector(openWeb3)
            let price = NSMenuItem(title: "", action: action, keyEquivalent: "")
            price.target = self
            let name = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            let stats = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            [price, name, stats].forEach {
                $0.isEnabled = true
                menu.addItem($0)
            }
            quotePriceItems.append(price)
            quoteNameItems.append(name)
            quoteStatsItems.append(stats)
            if slot < 2 { menu.addItem(.separator()) }
        }
        updatedItem.isEnabled = true
        menu.addItem(updatedItem)
        for (slot, ticker) in [symbol, symbol2, symbol3].enumerated() {
            quotePriceItems[slot].attributedTitle = styled("\(ticker)  \(t("loading"))",
                                                           size: 13, color: .secondaryLabelColor)
        }
        menu.addItem(.separator())
        balanceItem.isEnabled = true
        balanceItem.isHidden = true
        menu.addItem(balanceItem)
        balanceDetailItem.isEnabled = true
        balanceDetailItem.isHidden = true
        menu.addItem(balanceDetailItem)
        lifetimeItem.isEnabled = true
        lifetimeItem.isHidden = true
        menu.addItem(lifetimeItem)
        for _ in 0..<holdingSlots {
            let entry = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            entry.isEnabled = true
            entry.isHidden = true
            holdingItems.append(entry)
            menu.addItem(entry)
        }

        tpHeader.isEnabled = true
        tpHeader.isHidden = true
        menu.addItem(tpHeader)
        for _ in 0..<holdingSlots {
            let entry = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            entry.isEnabled = true
            entry.isHidden = true
            tpItems.append(entry)
            menu.addItem(entry)
        }
        tpTotalItem.isEnabled = true
        tpTotalItem.isHidden = true
        menu.addItem(tpTotalItem)

        menu.addItem(.separator())
        for (header, storage) in [(newsHeader, 0), (newsHeader2, 1), (newsHeader3, 2)] {
            header.isEnabled = true
            menu.addItem(header)
            for _ in 0..<newsCount {
                let entry = NSMenuItem(title: "", action: #selector(openNews(_:)), keyEquivalent: "")
                entry.target = self
                entry.isEnabled = true
                entry.isHidden = true
                switch storage {
                case 0: newsItems.append(entry)
                case 1: newsItems2.append(entry)
                default: newsItems3.append(entry)
                }
                menu.addItem(entry)
            }
            if storage < 2 { menu.addItem(.separator()) }
        }
        menu.addItem(.separator())
        symbolItem = NSMenuItem(title: "", action: #selector(changeSymbol), keyEquivalent: "s")
        symbolItem.target = self
        menu.addItem(symbolItem)
        symbolItem2 = NSMenuItem(title: "", action: #selector(changeSymbol2), keyEquivalent: "d")
        symbolItem2.target = self
        menu.addItem(symbolItem2)
        symbolItem3 = NSMenuItem(title: "", action: #selector(changeSymbol3), keyEquivalent: "3")
        symbolItem3.target = self
        menu.addItem(symbolItem3)
        computeItem = NSMenuItem(title: "", action: #selector(toggleCompute), keyEquivalent: "y")
        computeItem.target = self
        computeItem.state = computeFromExport ? .on : .off
        menu.addItem(computeItem)
        dashboardItem = NSMenuItem(title: "", action: #selector(showDashboard), keyEquivalent: "0")
        dashboardItem.target = self
        menu.addItem(dashboardItem)
        depositsItem = NSMenuItem(title: "", action: #selector(editDeposits), keyEquivalent: "n")
        depositsItem.target = self
        menu.addItem(depositsItem)
        tpMenuItem = NSMenuItem(title: "", action: #selector(editTargets), keyEquivalent: "t")
        tpMenuItem.target = self
        menu.addItem(tpMenuItem)
        percentItem = NSMenuItem(title: "", action: #selector(togglePercent), keyEquivalent: "p")
        percentItem.target = self
        percentItem.state = showPercent ? .on : .off
        menu.addItem(percentItem)
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
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.refreshPortfolio()
        }.tolerance = 5

        // News changes rarely, so it gets its own 5-minute timer instead of hammering the endpoint.
        refreshNews()
        newsTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refreshNews()
        }
        newsTimer?.tolerance = 30

        portfolio = Portfolio.load()
        refreshPortfolio()

        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged),
                                               name: .settingsChanged, object: nil)

        // The Chrome extension pushes the Trading 212 balance here; the widget never scrapes anything itself.
        balanceServer = BalanceServer { [weak self] balance in
            DispatchQueue.main.async {
                self?.calibrateCash(from: balance)
                self?.renderBalance(balance)
            }
        }
        balanceServer?.start(port: balancePort)
    }

    @objc func switchLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let lang = Lang(rawValue: raw) else { return }
        Lang.current = lang
        sender.menu?.items.forEach { $0.state = ($0.representedObject as? String) == raw ? .on : .off }
        applyLanguage()
        if lastQuote != nil { render(lastQuote) }   // redraw what we have, don't wait for the next poll
        renderSecondary(nil)
        refreshNews()
    }

    // Static menu labels; dynamic lines are translated inside render/renderNews.
    func applyLanguage() {
        newsHeader.attributedTitle = newsTitle(symbol)
        newsHeader2.attributedTitle = newsTitle(symbol2)
        newsHeader3.attributedTitle = newsTitle(symbol3)
        symbolItem.title = String(format: t("symbol"), symbol)
        symbolItem2.title = String(format: t("symbol2"), symbol2)
        symbolItem3.title = String(format: t("symbol3"), symbol3.isEmpty ? t("none") : symbol3)
        computeItem.title = t("computeToggle")
        percentItem.title = t("showPercent")
        tpMenuItem.title = t("tp")
        depositsItem.title = t("setDeposits")
        dashboardItem.title = t("dashboard")
        refreshItem.title = t("refresh")
        webItem.title = t("openWeb")
        languageItem.title = t("language")
        quitItem.title = t("quit")
        if lastQuote == nil, !quotePriceItems.isEmpty {
            quotePriceItems[0].attributedTitle = styled("\(symbol)  \(t("loading"))", size: 13, color: .secondaryLabelColor)
        }
        if lastQuote2 == nil, quotePriceItems.count > 1 {
            quotePriceItems[1].attributedTitle = styled("\(symbol2)  \(t("loading"))", size: 13, color: .secondaryLabelColor)
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
        fetch(entered) { [weak self] quote in
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

    @objc func changeSymbol2() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = t("changeSymbol")
        alert.informativeText = t("changeSymbolInfo")
        alert.addButton(withTitle: t("ok"))
        alert.addButton(withTitle: t("cancel"))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = symbol2
        field.placeholderString = "KOD"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let entered = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !entered.isEmpty, entered != symbol2 else { return }

        let previous = symbol2
        symbol2 = entered
        lastQuote2 = nil
        applyLanguage()
        fetch(entered) { [weak self] quote in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let quote = quote {
                    self.renderSecondary(quote)
                } else {
                    symbol2 = previous
                    self.applyLanguage()
                    let warning = NSAlert()
                    warning.messageText = String(format: self.t("unknownSymbol"), previous)
                    warning.runModal()
                    self.refresh()
                }
            }
        }
    }

    @objc func showDashboard() {
        if let window = dashboardWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "\(symbol) · \(symbol2)"
        window.titlebarAppearsTransparent = true
        window.contentViewController = NSHostingController(rootView: DashboardView())
        window.center()
        window.isReleasedWhenClosed = false
        dashboardWindow = window

        // Stays an accessory app: launchd runs the executable directly rather than through
        // LaunchServices, and a Dock tile for such a process renders with a prohibitory badge.
        // An accessory app's windows still take focus and keyboard input.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        pushDashboard()
    }

    func pushDashboard() {
        var quotes: [(String, Quote)] = []
        if let q = lastQuote { quotes.append((symbol, q)) }
        if let q = lastQuote2 { quotes.append((symbol2, q)) }
        if let q = lastQuote3, !symbol3.isEmpty { quotes.append((symbol3, q)) }
        DashboardModel.shared.push(quotes: quotes, computed: computed, balance: balance, portfolio: portfolio)
    }

    @objc func settingsChanged() {
        applyLanguage()
        lastQuote = nil
        lastQuote2 = nil
        lastQuote3 = nil
        priceCache.removeAll()
        dashboardWindow?.title = "\(symbol) · \(symbol2)"
        refresh()
        refreshNews()
        refreshPortfolio()
    }

    @objc func editDeposits() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = t("setDeposits")
        alert.informativeText = t("setDepositsInfo")
        alert.addButton(withTitle: t("ok"))
        alert.addButton(withTitle: t("cancel"))

        let form = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 56))
        let rows: [(String, Double)] = [(t("deposits"), depositsTotal), (t("withdrawals"), withdrawalsTotal)]
        var fields: [NSTextField] = []
        for (index, row) in rows.enumerated() {
            let y = 30 - CGFloat(index) * 30
            let label = NSTextField(labelWithString: row.0)
            label.frame = NSRect(x: 0, y: y + 3, width: 110, height: 20)
            let field = NSTextField(frame: NSRect(x: 116, y: y, width: 150, height: 22))
            if row.1 != 0 { field.stringValue = String(format: "%.2f", abs(row.1)) }
            field.placeholderString = "0.00"
            fields.append(field)
            form.addSubview(label)
            form.addSubview(field)
        }
        alert.accessoryView = form
        alert.window.initialFirstResponder = fields[0]

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        func amount(_ field: NSTextField) -> Double {
            let text = field.stringValue
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "\u{00a0}", with: "")
                .replacingOccurrences(of: ",", with: ".")
            return abs(Double(text) ?? 0)
        }
        depositsTotal = amount(fields[0])
        withdrawalsTotal = amount(fields[1])
        recompute()
    }

    @objc func editTargets() {
        guard let portfolio = portfolio else { return }
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = t("tpSetTitle")
        alert.informativeText = t("tpSetInfo")
        alert.addButton(withTitle: t("ok"))
        alert.addButton(withTitle: t("cancel"))

        let rowHeight: CGFloat = 26
        let form = NSView(frame: NSRect(x: 0, y: 0, width: 260,
                                        height: rowHeight * CGFloat(portfolio.positions.count)))
        var fields: [String: NSTextField] = [:]
        let saved = takeProfit
        for (index, position) in portfolio.positions.enumerated() {
            let y = form.frame.height - rowHeight * CGFloat(index + 1)
            let label = NSTextField(labelWithString: position.symbol)
            label.frame = NSRect(x: 0, y: y + 3, width: 70, height: 20)
            let field = NSTextField(frame: NSRect(x: 76, y: y, width: 120, height: 22))
            field.placeholderString = String(format: "%.2f", position.avgPrice)
            if let target = saved[position.symbol] { field.stringValue = String(format: "%g", target) }
            fields[position.symbol] = field
            form.addSubview(label)
            form.addSubview(field)
        }
        alert.accessoryView = form
        alert.window.initialFirstResponder = fields[portfolio.positions[0].symbol]

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var targets: [String: Double] = [:]
        for (symbol, field) in fields {
            let text = field.stringValue.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
            if let value = Double(text), value > 0 { targets[symbol] = value }
        }
        takeProfit = targets
        recompute()
    }

    @objc func togglePercent() {
        showPercent.toggle()
        percentItem.state = showPercent ? .on : .off
        if lastQuote != nil { render(lastQuote) }
    }

    @objc func openWeb3() {
        guard !symbol3.isEmpty else { return }
        NSWorkspace.shared.open(URL(string: "https://finance.yahoo.com/quote/\(symbol3)")!)
    }

    @objc func toggleCompute() {
        computeFromExport.toggle()
        computeItem.state = computeFromExport ? .on : .off
        if computeFromExport {
            refreshPortfolio()
        } else {
            computed = nil
            renderBalance(nil)
            if lastQuote != nil { render(lastQuote) }
        }
    }

    @objc func changeSymbol3() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = t("changeSymbol")
        alert.informativeText = t("changeSymbolInfo")
        alert.addButton(withTitle: t("ok"))
        alert.addButton(withTitle: t("cancel"))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = symbol3
        field.placeholderString = t("none")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let entered = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard entered != symbol3 else { return }

        // An empty field simply drops the third block.
        if entered.isEmpty {
            symbol3 = ""
            lastQuote3 = nil
            applyLanguage()
            renderThird(nil)
            return
        }

        let previous = symbol3
        symbol3 = entered
        lastQuote3 = nil
        applyLanguage()
        fetch(entered) { [weak self] quote in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let quote = quote {
                    self.renderThird(quote)
                    self.refreshNews()
                } else {
                    symbol3 = previous
                    self.applyLanguage()
                    let warning = NSAlert()
                    warning.messageText = String(format: self.t("unknownSymbol"), previous.isEmpty ? self.t("none") : previous)
                    warning.runModal()
                }
            }
        }
    }

    @objc func openWeb2() {
        NSWorkspace.shared.open(URL(string: "https://finance.yahoo.com/quote/\(symbol2)")!)
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

    func newsTitle(_ ticker: String) -> NSAttributedString {
        styled("\(t("news")) · \(ticker)", size: 11, weight: .semibold, color: .secondaryLabelColor)
    }

    func refreshNews() {
        loadNews(for: symbol) { [weak self] items in self?.renderNews(items, into: self?.newsItems ?? [], header: self?.newsHeader) }
        loadNews(for: symbol2) { [weak self] items in self?.renderNews(items, into: self?.newsItems2 ?? [], header: self?.newsHeader2) }
        if !symbol3.isEmpty {
            loadNews(for: symbol3) { [weak self] items in self?.renderNews(items, into: self?.newsItems3 ?? [], header: self?.newsHeader3) }
        }
    }

    func loadNews(for ticker: String, _ completion: @escaping ([NewsItem]) -> Void) {
        let url = URL(string: "https://query1.finance.yahoo.com/v1/finance/search?q=\(ticker)&newsCount=\(newsCount)&quotesCount=0")!
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        URLSession.shared.dataTask(with: req) { data, _, _ in
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
            DispatchQueue.main.async { completion(items) }
        }.resume()
    }

    func renderNews(_ items: [NewsItem], into slots: [NSMenuItem], header: NSMenuItem?) {
        header?.isHidden = items.isEmpty
        for (index, entry) in slots.enumerated() {
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

    // The secondary symbol gets a compact block: price with change, then its ranges.
    // The base marker stays with the primary one; news is shown for both.
    func renderThird(_ quote: Quote?) {
        let visible = !symbol3.isEmpty
        [quotePriceItems, quoteNameItems, quoteStatsItems].forEach { items in
            if items.count > 2 { items[2].isHidden = !visible }
        }
        newsHeader3.isHidden = !visible
        newsItems3.forEach { $0.isHidden = !visible }
        guard visible, let q = quote ?? lastQuote3 else { return }
        lastQuote3 = q
        renderQuoteBlock(ticker: symbol3, quote: q, slot: 2)
        pushDashboard()
        if lastQuote != nil { render(lastQuote) }
    }

    func renderSecondary(_ quote: Quote?) {
        guard let q = quote ?? lastQuote2 else { return }
        lastQuote2 = q
        renderQuoteBlock(ticker: symbol2, quote: q, slot: 1)
        pushDashboard()
        if lastQuote != nil { render(lastQuote) }   // the title carries both quotes
    }

    // Prices for every position symbol, not just the two on display, plus the FX rates
    // that carry instrument currency into account currency.
    func refreshPortfolio() {
        guard computeFromExport, let portfolio = portfolio else { return }

        let symbols = Set(portfolio.positions.map(\.symbol))
        let pairs = Set(portfolio.positions.map(\.currency))
            .filter { $0 != portfolio.accountCurrency }
            .map { "\($0)\(portfolio.accountCurrency)=X" }

        let group = DispatchGroup()
        for ticker in symbols {
            group.enter()
            fetch(ticker) { [weak self] quote in
                if let quote = quote { self?.priceCache[ticker] = quote.price }
                group.leave()
            }
        }
        for pair in pairs {
            group.enter()
            fetch(pair) { [weak self] quote in
                if let quote = quote { self?.fxCache[pair] = quote.price }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in self?.recompute() }
    }

    func rate(from currency: String) -> Double? {
        guard let portfolio = portfolio else { return nil }
        if currency == portfolio.accountCurrency { return 1 }
        return fxCache["\(currency)\(portfolio.accountCurrency)=X"]
    }

    func recompute() {
        guard computeFromExport, let portfolio = portfolio else { return }

        let cashNow = UserDefaults.standard.object(forKey: "cashCalibrated") as? Double ?? portfolio.cashFallback
        var unrealized = 0.0, notional = 0.0, margin = 0.0, priced = 0
        var holdings: [Holding] = []
        for position in portfolio.positions {
            guard let price = priceCache[position.symbol],
                  let fx = rate(from: position.currency) else { continue }
            priced += 1

            // A position is valued at the price it would close at and margined at the other
            // side of the spread, which is how the platform's own totals come out.
            let value = position.units * position.closingPrice(from: price) * fx
            let positionMargin = position.units * position.marginPrice(from: price) * fx / position.leverage
            let pnl = position.sign * position.units * (position.closingPrice(from: price) - position.avgPrice) * fx
            let result = pnl - fxFeeRate * abs(pnl)   // 0.5% FX fee, charged either way

            unrealized += result
            notional += value
            margin += positionMargin
            holdings.append(Holding(symbol: position.symbol, lots: position.lots,
                                    result: result, value: value, margin: positionMargin))
        }
        guard priced == portfolio.positions.count, margin > 0 else { return }

        // The same arithmetic at the target prices; a symbol without a target keeps its
        // current price, so a partly filled set of targets still answers "and then what".
        let targets = takeProfit
        var scenario: Scenario?
        if !targets.isEmpty {
            var sResult = 0.0, sMargin = 0.0, sHoldings: [Holding] = []
            for position in portfolio.positions {
                guard let price = priceCache[position.symbol],
                      let fx = rate(from: position.currency) else { continue }
                let closing = targets[position.symbol] ?? position.closingPrice(from: price)
                let marginPrice = targets[position.symbol].map { $0 + position.sign * position.spread }
                    ?? position.marginPrice(from: price)
                let pnl = position.sign * position.units * (closing - position.avgPrice) * fx
                let result = pnl - fxFeeRate * abs(pnl)
                let positionMargin = position.units * marginPrice * fx / position.leverage
                sResult += result
                sMargin += positionMargin
                sHoldings.append(Holding(symbol: position.symbol, lots: position.lots, result: result,
                                         value: position.units * closing * fx, margin: positionMargin))
            }
            let sEquity = cashNow + sResult
            let sHealth = sEquity < sMargin ? sEquity / sMargin * 50 : sEquity / (sEquity + sMargin) * 100
            scenario = Scenario(equity: sEquity, result: sResult, margin: sMargin, health: sHealth,
                                freeFunds: max(sEquity - sMargin, 0), holdings: sHoldings,
                                covered: targets.count)
        }

        // Cash is calibrated against the platform's own equity whenever a live reading
        // arrives; between readings it only moves with realised events, which are rare.
        let equity = cashNow + unrealized

        // Trading 212's account status: below 50% it is measured against the margin alone,
        // above it against funds plus margin. Both branches meet at 50%.
        let health = equity < margin ? equity / margin * 50 : equity / (equity + margin) * 100

        computed = Computed(unrealized: unrealized, equity: equity, notional: notional,
                            margin: margin, health: health,
                            freeFunds: max(equity - margin, 0),
                            priced: priced, total: portfolio.positions.count,
                            holdings: holdings, scenario: scenario)
        if Date().timeIntervalSince(lastComputeLog) > 60 {
            lastComputeLog = Date()
            FileHandle.standardError.write(
                String(format: "computed: equity=%.0f pnl=%.0f margin=%.0f health=%.1f%% free=%.0f\n",
                       equity, unrealized, margin, health, computed?.freeFunds ?? 0)
                    .data(using: .utf8)!)
        }
        renderBalance(nil)
        if lastQuote != nil { render(lastQuote) }
    }

    // A fresh platform reading pins two things down: the cash, and how far our result sits
    // from theirs. They value longs at the bid and fold overnight interest into the result,
    // so the gap is a near-constant offset rather than noise.
    func calibrateCash(from balance: Balance) {
        // Only while the CFD market is actually open. Outside the session the platform's
        // figures are frozen at the close, and pinning cash to them would drag our own
        // equity back to that frozen number — exactly what this calculation exists to avoid.
        guard lastQuote?.session == .regular else { return }
        guard !balance.hidden, let computed = computed else { return }
        UserDefaults.standard.set(balance.value - computed.unrealized, forKey: "cashCalibrated")
        if let platformPnl = balance.pnl {
            UserDefaults.standard.set(platformPnl - computed.unrealized, forKey: "pnlOffset")
        }
    }

    func renderBalance(_ balance: Balance?) {
        if let balance = balance { self.balance = balance }

        // While the platform is live it is the authority — those are the numbers the account
        // actually trades on. The moment its session closes or the tab goes away, its figures
        // freeze, so the Yahoo-based calculation takes over.
        let platformLive = self.balance.map { account in
            !account.hidden
                && Date().timeIntervalSince(account.received) <= 90
                && lastQuote?.session == .regular
        } ?? false

        guard computeFromExport, let computed = computed, !platformLive else {
            renderScrapedOnly()
            return
        }
        let currency = portfolio?.accountCurrency ?? ""
        balanceItem.isHidden = false
        balanceDetailItem.isHidden = false

        let result = computed.unrealized + (UserDefaults.standard.object(forKey: "pnlOffset") as? Double ?? 0)
        let positive = result >= 0
        // Trading 212 quotes the result against account value, not against what was invested.
        let percent = computed.equity != 0 ? abs(result / computed.equity) * 100 : 0

        let line = NSMutableAttributedString()
        line.append(icon("wallet.bifold.fill", color: .secondaryLabelColor, size: 12))
        line.append(styled("  " + grouped(computed.equity) + " ", size: 16, weight: .semibold, mono: true))
        line.append(styled(currency, size: 11, weight: .medium, color: .secondaryLabelColor))
        line.append(styled("     " + signed(result), size: 13, weight: .semibold,
                           color: accentColor(up: positive), mono: true))
        line.append(styled(String(format: "  (%.2f%%)", percent), size: 11,
                           color: accentColor(up: positive), mono: true))
        balanceItem.attributedTitle = line

        let detail = NSMutableAttributedString()
        detail.append(field(t("margin"), grouped(computed.margin), color: .secondaryLabelColor))
        detail.append(field(t("health"), String(format: "%.0f%%", computed.health),
                            color: computed.health < 40 ? .systemOrange : .labelColor))
        detail.append(field(t("cash"), grouped(computed.freeFunds), color: .secondaryLabelColor))

        // The platform's own reading stays visible as a cross-check while it is live.
        var note = t("computed")
        if let account = self.balance, Date().timeIntervalSince(account.received) <= 90, !account.hidden {
            note += "   ·   \(t("platform")) \(grouped(account.value))"
        }
        detail.append(styled("   " + note, size: 10, color: .tertiaryLabelColor))
        balanceDetailItem.attributedTitle = detail

        pushDashboard()
        renderLifetime(computed)
        renderHoldings(computed.holdings)
        renderScenario(computed)
        if lastQuote != nil { render(lastQuote) }   // the title carries equity and health
    }

    // Equity against the money actually put in: what the account made or lost overall,
    // realised trades included, rather than just on the positions open right now.
    func renderLifetime(_ computed: Computed) {
        let invested = netDeposits
        guard invested != 0 else {
            lifetimeItem.isHidden = true
            return
        }
        lifetimeItem.isHidden = false
        let overall = computed.equity - invested
        let up = overall >= 0
        let line = NSMutableAttributedString()
        line.append(field(t("invested"), grouped(invested), color: .secondaryLabelColor))
        line.append(styled(t("lifetime") + " ", size: 10, weight: .medium, color: .tertiaryLabelColor))
        line.append(styled(signed(overall), size: 12, weight: .semibold,
                           color: accentColor(up: up), mono: true))
        if invested > 0 {
            line.append(styled(String(format: "  (%+.1f%%)", overall / invested * 100),
                               size: 10, color: accentColor(up: up), mono: true))
        }
        lifetimeItem.attributedTitle = line
    }

    func renderScenario(_ computed: Computed) {
        guard let scenario = computed.scenario else {
            tpHeader.isHidden = true
            tpItems.forEach { $0.isHidden = true }
            tpTotalItem.isHidden = true
            return
        }
        let currency = portfolio?.accountCurrency ?? ""
        tpHeader.isHidden = false
        tpHeader.attributedTitle = styled(t("atTarget"), size: 10, weight: .semibold, color: .tertiaryLabelColor)

        let targets = takeProfit
        let resultWidth = scenario.holdings.map { grouped($0.result).count }.max() ?? 10
        for (index, entry) in tpItems.enumerated() {
            guard index < scenario.holdings.count else {
                entry.isHidden = true
                continue
            }
            let holding = scenario.holdings[index]
            entry.isHidden = false
            let up = holding.result >= 0
            let line = NSMutableAttributedString()
            line.append(styled(pad(holding.symbol, 7), size: 12, weight: .semibold, mono: true))
            let target = targets[holding.symbol].map { "→ " + String(format: "%g", $0) } ?? "—"
            line.append(styled(pad(target, 10), size: 11, color: .secondaryLabelColor, mono: true))
            line.append(styled(pad(signed(holding.result), resultWidth + 2, right: true),
                               size: 12, weight: .semibold, color: accentColor(up: up), mono: true))
            entry.attributedTitle = line
        }

        tpTotalItem.isHidden = false
        let up = scenario.result >= 0
        let delta = scenario.equity - computed.equity
        let total = NSMutableAttributedString()
        total.append(icon("target", color: .secondaryLabelColor, size: 12))
        total.append(styled("  " + grouped(scenario.equity) + " ", size: 15, weight: .semibold, mono: true))
        total.append(styled(currency, size: 11, weight: .medium, color: .secondaryLabelColor))
        total.append(styled("     " + signed(scenario.result) + "      ", size: 13, weight: .semibold,
                            color: accentColor(up: up), mono: true))
        total.append(field(t("health"), String(format: "%.0f%%", scenario.health), color: .secondaryLabelColor))
        total.append(field(t("cash"), grouped(scenario.freeFunds), color: .secondaryLabelColor))
        total.append(field(t("upside"), signed(delta), color: accentColor(up: delta >= 0)))

        let invested = netDeposits
        if invested != 0 {
            let overall = scenario.equity - invested
            total.append(field(t("lifetime"), signed(overall), color: accentColor(up: overall >= 0)))
        }
        tpTotalItem.attributedTitle = total
    }

    // Per-symbol totals, the same three rows the platform shows under each instrument.
    func renderHoldings(_ holdings: [Holding]) {
        let resultWidth = holdings.map { grouped($0.result).count }.max() ?? 10
        for (index, entry) in holdingItems.enumerated() {
            guard index < holdings.count else {
                entry.isHidden = true
                continue
            }
            let holding = holdings[index]
            entry.isHidden = false

            let up = holding.result >= 0
            let line = NSMutableAttributedString()
            line.append(styled(pad(holding.symbol, 7), size: 12, weight: .semibold, mono: true))
            line.append(styled(pad("\(holding.lots) \(t("lots"))", 10),
                               size: 10, color: .tertiaryLabelColor, mono: true))
            line.append(styled(pad(signed(holding.result), resultWidth + 2, right: true) + "      ",
                               size: 12, weight: .semibold, color: accentColor(up: up), mono: true))
            line.append(field(t("value"), grouped(holding.value), color: .secondaryLabelColor))
            line.append(field(t("margin"), grouped(holding.margin), color: .secondaryLabelColor))
            entry.attributedTitle = line
        }
    }

    // Without positions.json there is nothing to compute from, so the scraped numbers
    // are shown as they arrive.
    func renderScrapedOnly() {
        guard let account = balance else {
            balanceItem.isHidden = true
            balanceDetailItem.isHidden = true
            return
        }
        balanceItem.isHidden = false
        balanceDetailItem.isHidden = false

        let stale = Date().timeIntervalSince(account.received) > 90
        let line = NSMutableAttributedString()
        line.append(icon("wallet.bifold.fill", color: .secondaryLabelColor, size: 11))
        line.append(styled(String(format: "  %@  %@ %@", t("balance"), grouped(account.value), account.currency),
                           size: 13, weight: .semibold,
                           color: stale ? .secondaryLabelColor : .labelColor, mono: true))
        if let pnl = account.pnl {
            let positive = pnl >= 0
            var text = String(format: "   %@%@", positive ? "+" : "−", grouped(abs(pnl)))
            if let percent = account.pnlPercent { text += String(format: "  (%.2f%%)", abs(percent)) }
            line.append(styled(text, size: 12, weight: .medium,
                               color: stale ? .secondaryLabelColor : accentColor(up: positive), mono: true))
        }
        balanceItem.attributedTitle = line

        var parts: [String] = []
        if let margin = account.margin { parts.append("\(t("margin"))  \(grouped(margin))") }
        if let health = account.health { parts.append("\(t("health"))  \(health)") }
        if let cash = account.cash { parts.append("\(t("cash"))  \(grouped(cash))") }
        let detail = NSMutableAttributedString()
        detail.append(styled(parts.joined(separator: "     ·     "),
                             size: 12, weight: .medium, color: .secondaryLabelColor, mono: true))
        var note = t("platform") + " · " + relative(account.received)
        if computeFromExport && computed == nil { note += " · " + t("noPositions") }
        if account.hidden { note += " · " + t("background") }
        detail.append(styled("   " + note, size: 10,
                             color: computed == nil ? .systemOrange : .tertiaryLabelColor))
        balanceDetailItem.attributedTitle = detail
        holdingItems.forEach { $0.isHidden = true }
        lifetimeItem.isHidden = true
        tpItems.forEach { $0.isHidden = true }
        tpHeader.isHidden = true
        tpTotalItem.isHidden = true
    }

    func quoteSegment(_ quote: Quote, accent: NSColor, arrow: String) -> NSAttributedString {
        let segment = NSMutableAttributedString()
        segment.append(styled(String(format: "%.2f", quote.price), size: 13, weight: .semibold, mono: true))
        if showPercent {
            segment.append(styled(String(format: " %@%.2f%%", arrow, abs(quote.changePercent)),
                                  size: 12, weight: .semibold, color: accent, mono: true))
        } else {
            // Without the number the arrow still carries the direction, and costs one glyph.
            segment.append(styled(" " + arrow, size: 10, weight: .bold, color: accent))
        }
        return segment
    }

    // Columns are padded by hand: these lines mix label and number weights, and a
    // monospaced digit font only lines up the digits, not the words between them.
    func pad(_ text: String, _ width: Int, right: Bool = false) -> String {
        let spaces = String(repeating: " ", count: max(0, width - text.count))
        return right ? spaces + text : text + spaces
    }

    func signed(_ value: Double) -> String { (value >= 0 ? "+" : "−") + grouped(abs(value)) }

    /// A muted label followed by its value, with even spacing after it.
    func field(_ label: String, _ value: String, color: NSColor = .labelColor) -> NSAttributedString {
        let part = NSMutableAttributedString()
        part.append(styled(label + " ", size: 10, weight: .medium, color: .tertiaryLabelColor))
        part.append(styled(value + "     ", size: 12, weight: .medium, color: color, mono: true))
        return part
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
        fetch(symbol) { [weak self] quote in
            DispatchQueue.main.async {
                self?.inFlight = false
                self?.render(quote)
                self?.renderBalance(nil)
            }
        }
        fetch(symbol2) { [weak self] quote in
            DispatchQueue.main.async { self?.renderSecondary(quote) }
        }
        if !symbol3.isEmpty {
            fetch(symbol3) { [weak self] quote in
                DispatchQueue.main.async { self?.renderThird(quote) }
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

    // Muted shades: the system green/red are too loud on a light menu bar,
    // while dark mode needs them lighter so they don't sink into the background.
    func accentColor(up: Bool) -> NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            if up {
                return dark ? NSColor(srgbRed: 0.28, green: 0.72, blue: 0.42, alpha: 1)
                            : NSColor(srgbRed: 0.10, green: 0.45, blue: 0.24, alpha: 1)
            }
            return dark ? NSColor(srgbRed: 0.92, green: 0.40, blue: 0.38, alpha: 1)
                        : NSColor(srgbRed: 0.62, green: 0.14, blue: 0.13, alpha: 1)
        }
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
        let accent = accentColor(up: up)
        let arrow = up ? "▲" : "▼"

        // Title: both quotes bare, then one session mark — both symbols share the same
        // market hours. Which price is which is settled by the order, same as in the menu.
        let title = NSMutableAttributedString()
        if TitlePart.first.isOn {
            title.append(quoteSegment(q, accent: accent, arrow: arrow))
        }
        let extras = [(lastQuote2, TitlePart.second), (lastQuote3, TitlePart.third)]
        for (quote, part) in extras {
            guard part.isOn, let quote = quote else { continue }
            let rising = quote.changePercent >= 0
            if title.length > 0 { title.append(NSAttributedString(string: "   ")) }
            title.append(quoteSegment(quote, accent: accentColor(up: rising), arrow: rising ? "▲" : "▼"))
        }
        // The session mark belongs to the quotes; without them it has nothing to qualify.
        if TitlePart.first.isOn || TitlePart.second.isOn || TitlePart.third.isOn {
            let mark = sessionIcon(q.session)
            title.append(NSAttributedString(string: "  "))
            title.append(icon(mark.symbol, color: mark.color, size: 10))
        }
        // The account total rides along after the session mark: same weight as the price
        // so it reads as a second figure, with a small "k" that stays out of the way.
        // Age is flagged with a mark rather than by dimming — a number worth showing is
        // worth showing legibly.
        let platformLive = balance.map { account in
            !account.hidden
                && Date().timeIntervalSince(account.received) <= 90
                && q.session == .regular
        } ?? false
        // The menu bar carries the overall figure — equity against the money put in —
        // since that is the number worth glancing at; the equity itself lives in the menu.
        let invested = netDeposits
        let equity = platformLive ? balance?.value : (computed?.equity ?? balance?.value)
        // Same meaning all day: whichever source is live, the title shows equity minus
        // the money put in. A field that silently changes meaning at the open is worse
        // than either figure on its own.
        let headline = invested != 0 ? equity.map { $0 - invested } : equity
        let healthPercent = platformLive
            ? balance?.health
            : (computed.map { String(format: "%.0f%%", $0.health) } ?? balance?.health)
        if let headline = headline, TitlePart.total.isOn {
            // The overall figure is signed and coloured; a bare equity is not.
            let overall = invested != 0
            title.append(NSAttributedString(string: "  "))
            title.append(styled(String(format: overall ? "%+.0f" : "%.0f", headline / 1000),
                                size: 13, weight: .semibold,
                                color: overall ? accentColor(up: headline >= 0) : .labelColor, mono: true))
            title.append(styled("k", size: 10, weight: .medium, color: .secondaryLabelColor))
        }

        // Health is the number that matters when it drops, so it is colored by level.
        if let health = healthPercent, TitlePart.health.isOn {
            let level = Double(health.filter("0123456789.".contains)) ?? 100
            let color: NSColor = level < 20
                ? NSColor(srgbRed: 0.72, green: 0.20, blue: 0.18, alpha: 1)
                : level < 40 ? NSColor(srgbRed: 0.72, green: 0.44, blue: 0.05, alpha: 1)
                : .labelColor
            title.append(NSAttributedString(string: "  "))
            title.append(icon("heart.fill", color: color, size: 9))
            title.append(styled(" " + health, size: 12, weight: .semibold, color: color, mono: true))
        }

        // Computed figures never go stale: they follow the Yahoo quotes.
        if TitlePart.total.isOn || TitlePart.health.isOn {
            let account = balance
            let ageing = computed == nil && (account.map { Date().timeIntervalSince($0.received) > 90 } ?? false)
            if ageing || (computed == nil && account?.hidden == true) {
                title.append(NSAttributedString(string: " "))
                title.append(icon(ageing ? "clock.badge.exclamationmark.fill" : "zzz",
                                  color: .systemOrange, size: 9))
            }
        }

        // Everything can be switched off; an empty status item would be unclickable.
        if title.length == 0 {
            title.append(styled(symbol, size: 12, weight: .semibold, color: .secondaryLabelColor))
        }
        item.button?.attributedTitle = title

        renderQuoteBlock(ticker: symbol, quote: q, slot: 0)
        pushDashboard()
    }

    // One shape for both symbols: price line, instrument line, then the numbers.
    // The base marker only appears on a symbol whose session drives the percentage.
    func renderQuoteBlock(ticker: String, quote q: Quote, slot: Int) {
        let up = q.changePercent >= 0
        let accent = accentColor(up: up)
        let mark = sessionIcon(q.session)

        let headline = NSMutableAttributedString()
        headline.append(styled(ticker + "  ", size: 11, weight: .semibold, color: .secondaryLabelColor))
        headline.append(styled(String(format: "%.4f %@", q.price, q.currency), size: 16, weight: .semibold, mono: true))
        headline.append(styled(String(format: "   %@%.4f  (%+.2f%%)", up ? "▲" : "▼", abs(q.change), q.changePercent),
                               size: 12, weight: .medium, color: accent, mono: true))
        headline.append(NSAttributedString(string: "  "))
        headline.append(icon(mark.symbol, color: mark.color, size: 10))
        quotePriceItems[slot].attributedTitle = headline

        let sessionName: String
        switch q.session {
        case .pre: sessionName = t("pre")
        case .regular: sessionName = t("regular")
        case .post: sessionName = t("post")
        case .closed: sessionName = t("closed")
        }
        quoteNameItems[slot].attributedTitle = styled("\(sessionName)  ·  \(q.name)",
                                                      size: 12, weight: .medium, color: .secondaryLabelColor)

        // Outside regular hours the percentage runs from the session close, inside it from
        // the previous close; the base marker follows.
        let extended = q.session == .pre || q.session == .post
        let stats = NSMutableAttributedString()
        stats.append(styled(String(format: "%@ %.2f", extended ? t("regularClose") : t("regularLive"), q.regularPrice),
                            size: 11, weight: extended ? .semibold : .regular, mono: true))
        if extended { stats.append(styled(" " + t("base"), size: 9, color: .tertiaryLabelColor)) }
        stats.append(styled(String(format: "  ·  %@ %.2f", t("prevClose"), q.previousClose),
                            size: 11, weight: extended ? .regular : .semibold, mono: true))
        if !extended { stats.append(styled(" " + t("base"), size: 9, color: .tertiaryLabelColor)) }

        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        stats.append(styled(String(format: "  ·  %@ %.2f – %.2f  ·  %@ %.2f – %.2f  ·  %@ %@",
                                   t("day"), q.dayLow, q.dayHigh,
                                   t("week52"), q.weekLow, q.weekHigh,
                                   t("tick"), fmt.string(from: q.tickTime) as NSString),
                            size: 11, mono: true))
        quoteStatsItems[slot].attributedTitle = NSAttributedString(
            attributedString: applyColor(.secondaryLabelColor, to: stats))
    }

    // The stats line mixes weights but keeps one color.
    func applyColor(_ color: NSColor, to text: NSAttributedString) -> NSAttributedString {
        let copy = NSMutableAttributedString(attributedString: text)
        copy.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: copy.length))
        return copy
    }

    func fetch(_ ticker: String, _ completion: @escaping (Quote?) -> Void) {
        let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(ticker)?interval=1m&range=1d&includePrePost=true")!
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
                name: meta["longName"] as? String ?? ticker,
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
