import SwiftUI

/// What the dashboard window draws. The menu bar code pushes into it, so both views
/// always show the same numbers without recomputing anything twice.
final class DashboardModel: ObservableObject {
    static let shared = DashboardModel()

    @Published var quotes: [(ticker: String, quote: Quote)] = []
    @Published var computed: Computed?
    @Published var balance: Balance?
    @Published var positions: [Position] = []
    @Published var accountCurrency = "CZK"
    @Published var updated = Date()

    func push(quotes: [(String, Quote)], computed: Computed?, balance: Balance?, portfolio: Portfolio?) {
        self.quotes = quotes.map { (ticker: $0.0, quote: $0.1) }
        self.computed = computed
        self.balance = balance
        self.positions = portfolio?.positions ?? []
        self.accountCurrency = portfolio?.accountCurrency ?? "CZK"
        self.updated = Date()
    }
}

// MARK: - formatting

private let decimal: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.groupingSeparator = " "
    f.maximumFractionDigits = 0
    return f
}()

func amount(_ value: Double) -> String { decimal.string(from: NSNumber(value: value)) ?? "—" }
func signedAmount(_ value: Double) -> String { (value >= 0 ? "+" : "−") + amount(abs(value)) }

/// Large sums are easier to compare at a glance in thousands.
func compact(_ value: Double) -> String {
    let thousands = value / 1000
    return abs(thousands) >= 100
        ? String(format: "%.0fk", thousands)
        : String(format: "%.1fk", thousands)
}

extension Color {
    static func trend(_ up: Bool) -> Color {
        up ? Color(red: 0.10, green: 0.54, blue: 0.30) : Color(red: 0.74, green: 0.21, blue: 0.18)
    }
}

// MARK: - pieces

/// A number with a caption underneath, sized down so captions never compete with values.
struct Metric: View {
    let value: String
    let caption: String
    var color: Color = .primary
    var size: CGFloat = 15

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(caption)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct HealthRing: View {
    let health: Double

    private var color: Color {
        health < 25 ? .red : health < 45 ? .orange : Color(red: 0.10, green: 0.54, blue: 0.30)
    }

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 5)
            Circle()
                .trim(from: 0, to: min(health, 100) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(health))")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .frame(width: 46, height: 46)
    }
}

struct Panel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - dashboard

struct DashboardView: View {
    @ObservedObject var model = DashboardModel.shared
    @State private var showSettings = false
    @State private var showDetail = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                hero
                quotes
                if let computed = model.computed, !computed.holdings.isEmpty { positions(computed) }
                if let scenario = model.computed?.scenario { targets(scenario) }
            }
            .padding(18)
        }
        .frame(minWidth: 560, minHeight: 500)
        .background(.background)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                    .help("Settings")
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    // The account, with nothing but the figures that change a decision.
    @ViewBuilder private var hero: some View {
        if let computed = model.computed {
            let up = computed.unrealized >= 0
            let invested = netDeposits
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(amount(computed.equity))
                                .font(.system(size: 38, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                            Text(model.accountCurrency)
                                .font(.system(size: 13))
                                .foregroundStyle(.tertiary)
                        }
                        Text(signedAmount(computed.unrealized))
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Color.trend(up))
                    }
                    Spacer()
                    HealthRing(health: computed.health)
                }

                HStack(spacing: 0) {
                    Metric(value: compact(computed.margin), caption: "margin")
                    Metric(value: compact(computed.freeFunds), caption: "free")
                    if invested != 0 {
                        Metric(value: compact(invested), caption: "net in")
                        Metric(value: signedAmount(computed.equity - invested),
                               caption: "overall",
                               color: .trend(computed.equity - invested >= 0))
                    }
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private var quotes: some View {
        HStack(spacing: 12) {
            ForEach(model.quotes, id: \.ticker) { entry in
                quoteTile(entry.ticker, entry.quote)
            }
        }
    }

    private func quoteTile(_ ticker: String, _ q: Quote) -> some View {
        let up = q.changePercent >= 0
        return Panel {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(ticker).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        Image(systemName: sessionIcon(q.session))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    Text(String(format: "%.2f", q.price))
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                Spacer()
                Text(String(format: "%@%.2f%%", up ? "▲" : "▼", abs(q.changePercent)))
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.trend(up))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.trend(up).opacity(0.12), in: Capsule())
            }
        }
    }

    private func sessionIcon(_ session: Session) -> String {
        switch session {
        case .pre: return "sunrise.fill"
        case .regular: return "sun.max.fill"
        case .post: return "sunset.fill"
        case .closed: return "moon.fill"
        }
    }

    // Each position as a bar: the share of the book it takes, coloured by its result.
    private func positions(_ computed: Computed) -> some View {
        let total = computed.holdings.map(\.value).reduce(0, +)
        return Panel {
            VStack(spacing: 12) {
                ForEach(computed.holdings, id: \.symbol) { holding in
                    VStack(spacing: 5) {
                        HStack {
                            Text(holding.symbol).font(.system(size: 13, weight: .semibold))
                            Text("\(holding.lots)")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.quaternary.opacity(0.4), in: Capsule())
                            Spacer()
                            Text(signedAmount(holding.result))
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(Color.trend(holding.result >= 0))
                        }
                        GeometryReader { geo in
                            let share = total > 0 ? holding.value / total : 0
                            ZStack(alignment: .leading) {
                                Capsule().fill(.quaternary.opacity(0.35))
                                Capsule().fill(Color.trend(holding.result >= 0).opacity(0.55))
                                    .frame(width: geo.size.width * share)
                            }
                        }
                        .frame(height: 4)
                        if showDetail {
                            HStack {
                                Text("\(amount(holding.value)) value")
                                Spacer()
                                Text("\(amount(holding.margin)) margin")
                            }
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                        }
                    }
                }
                Button(showDetail ? "Hide value and margin" : "Show value and margin") {
                    withAnimation(.easeInOut(duration: 0.15)) { showDetail.toggle() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func targets(_ scenario: Scenario) -> some View {
        let delta = scenario.equity - (model.computed?.equity ?? scenario.equity)
        let invested = netDeposits
        return Panel {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "target").font(.system(size: 11)).foregroundStyle(.tertiary)
                    Text(amount(scenario.equity))
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(signedAmount(delta))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.trend(delta >= 0))
                    Spacer()
                    HealthRing(health: scenario.health).scaleEffect(0.8)
                }

                HStack(spacing: 8) {
                    ForEach(scenario.holdings, id: \.symbol) { holding in
                        HStack(spacing: 6) {
                            Text(holding.symbol).font(.system(size: 11, weight: .semibold))
                            Text(takeProfit[holding.symbol].map { String(format: "%g", $0) } ?? "—")
                                .font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit()
                            Text(signedAmount(holding.result))
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(Color.trend(holding.result >= 0))
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 7))
                    }
                    Spacer()
                    if invested != 0 {
                        Metric(value: signedAmount(scenario.equity - invested), caption: "overall",
                               color: .trend(scenario.equity - invested >= 0), size: 13)
                            .frame(maxWidth: 110)
                    }
                }
            }
        }
    }
}
