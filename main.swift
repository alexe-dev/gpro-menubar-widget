import Cocoa

let symbol = ProcessInfo.processInfo.environment["TICKER"] ?? "GPRO"
let refreshInterval: TimeInterval = Double(ProcessInfo.processInfo.environment["REFRESH"] ?? "") ?? 5

enum Session: String {
    case pre = "PRE", regular = "", post = "POST", closed = "CLOSED"
}

struct Quote {
    let price: Double          // последняя сделка, включая pre/post
    let changePercent: Double  // от базы текущей сессии
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var timer: Timer?
    let priceItem = NSMenuItem(title: "Загрузка…", action: nil, keyEquivalent: "")
    let sessionItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let regularItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let rangeItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let updatedItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    var inFlight = false

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
    }

    @objc func openWeb() {
        NSWorkspace.shared.open(URL(string: "https://finance.yahoo.com/quote/\(symbol)")!)
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

    // Неактивные пункты меню macOS рисует серым, поэтому задаём attributedTitle сами.
    func styled(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                color: NSColor = .labelColor, mono: Bool = false) -> NSAttributedString {
        let font = mono
            ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    }

    // SF Symbol как вложение в строку — рядом с текстом, с собственным цветом.
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
        // Приглушённые оттенки: на светлом меню-баре системные зелёный/красный слишком яркие,
        // в тёмной теме берём чуть светлее, чтобы не проваливались.
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

        // Титул: только цена, процент цветом и мелкая метка сессии — тикер виден в меню.
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

        // Во время основных торгов regularMarketPrice — это живая цена, а не закрытие,
        // и база для процента меняется: пре/пост считаем от закрытия, в сессии — от пред. закрытия.
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

            // Последний непустой тик минутного ряда — это и есть цена pre/post-маркета.
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

            // Сессия определяется по времени последнего тика в торговых периодах Yahoo.
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

            // В расширенных сессиях считаем изменение от закрытия основной сессии.
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
