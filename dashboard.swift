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

private let money: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.groupingSeparator = " "
    f.minimumFractionDigits = 2
    f.maximumFractionDigits = 2
    return f
}()

func amount(_ value: Double) -> String { money.string(from: NSNumber(value: value)) ?? "—" }
func signedAmount(_ value: Double) -> String { (value >= 0 ? "+" : "−") + amount(abs(value)) }

extension Color {
    static func trend(_ up: Bool) -> Color {
        up ? Color(red: 0.10, green: 0.52, blue: 0.29) : Color(red: 0.72, green: 0.20, blue: 0.18)
    }
}

// MARK: - building blocks

struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(.tertiary)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct Stat: View {
    let label: String
    let value: String
    var color: Color = .primary
    var size: CGFloat = 13

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - dashboard

struct DashboardView: View {
    @ObservedObject var model = DashboardModel.shared
    @State private var showSettings = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                quotesRow
                if let computed = model.computed { account(computed) }
                if let computed = model.computed, !computed.holdings.isEmpty { holdings(computed) }
                if let scenario = model.computed?.scenario { targets(scenario) }
            }
            .padding(16)
        }
        .frame(minWidth: 620, minHeight: 520)
        .background(.background)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showSettings = true
                } label: {
                    Label("Settings", systemImage: "slider.horizontal.3")
                }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    private var quotesRow: some View {
        HStack(spacing: 14) {
            ForEach(model.quotes, id: \.ticker) { entry in
                quoteCard(entry.ticker, entry.quote)
            }
        }
    }

    private func quoteCard(_ ticker: String, _ q: Quote) -> some View {
        let up = q.changePercent >= 0
        return Card(title: ticker) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(format: "%.4f", q.price))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(q.currency).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text(String(format: "%@%.4f  (%+.2f%%)", up ? "▲" : "▼", abs(q.change), q.changePercent))
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Color.trend(up))
            Divider()
            HStack {
                Text(sessionLabel(q.session))
                Spacer()
                Text(q.name).foregroundStyle(.secondary).lineLimit(1)
            }
            .font(.system(size: 11))
            HStack {
                Text("Day \(String(format: "%.2f – %.2f", q.dayLow, q.dayHigh))")
                Spacer()
                Text("52wk \(String(format: "%.2f – %.2f", q.weekLow, q.weekHigh))")
            }
            .font(.system(size: 10))
            .monospacedDigit()
            .foregroundStyle(.tertiary)
        }
    }

    private func sessionLabel(_ session: Session) -> String {
        switch session {
        case .pre: return "Pre-market"
        case .regular: return "Regular hours"
        case .post: return "After hours"
        case .closed: return "Market closed"
        }
    }

    private func account(_ computed: Computed) -> some View {
        let up = computed.unrealized >= 0
        let invested = netDeposits
        return Card(title: "Account") {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(amount(computed.equity))
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(model.accountCurrency).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Text(signedAmount(computed.unrealized))
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.trend(up))
            }
            Divider()
            HStack(spacing: 0) {
                Stat(label: "Margin", value: amount(computed.margin))
                Stat(label: "Health", value: String(format: "%.0f%%", computed.health),
                     color: computed.health < 40 ? .orange : .primary)
                Stat(label: "Cash", value: amount(computed.freeFunds))
                if invested != 0 {
                    Stat(label: "Net in", value: amount(invested))
                    Stat(label: "Overall", value: signedAmount(computed.equity - invested),
                         color: .trend(computed.equity - invested >= 0))
                }
            }
            if let balance = model.balance {
                Text("T212 \(amount(balance.value)) · \(Int(Date().timeIntervalSince(balance.received)))s ago")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func holdings(_ computed: Computed) -> some View {
        Card(title: "Positions") {
            ForEach(computed.holdings, id: \.symbol) { holding in
                HStack(spacing: 12) {
                    Text(holding.symbol).font(.system(size: 13, weight: .semibold)).frame(width: 60, alignment: .leading)
                    Text("\(holding.lots) pos.").font(.system(size: 10)).foregroundStyle(.tertiary)
                        .frame(width: 56, alignment: .leading)
                    Text(signedAmount(holding.result))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.trend(holding.result >= 0))
                        .frame(width: 130, alignment: .trailing)
                    Spacer()
                    Stat(label: "Value", value: amount(holding.value), size: 11)
                    Stat(label: "Margin", value: amount(holding.margin), size: 11)
                }
            }
        }
    }

    private func targets(_ scenario: Scenario) -> some View {
        let invested = netDeposits
        let delta = scenario.equity - (model.computed?.equity ?? scenario.equity)
        return Card(title: "At targets") {
            ForEach(scenario.holdings, id: \.symbol) { holding in
                HStack(spacing: 12) {
                    Text(holding.symbol).font(.system(size: 13, weight: .semibold)).frame(width: 60, alignment: .leading)
                    Text(takeProfit[holding.symbol].map { "→ \(String(format: "%g", $0))" } ?? "—")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .leading)
                    Text(signedAmount(holding.result))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.trend(holding.result >= 0))
                        .frame(width: 130, alignment: .trailing)
                    Spacer()
                }
            }
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(amount(scenario.equity))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(model.accountCurrency).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text(signedAmount(scenario.result))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.trend(scenario.result >= 0))
            }
            HStack(spacing: 0) {
                Stat(label: "Health", value: String(format: "%.0f%%", scenario.health))
                Stat(label: "Cash", value: amount(scenario.freeFunds))
                Stat(label: "vs now", value: signedAmount(delta), color: .trend(delta >= 0))
                if invested != 0 {
                    Stat(label: "Overall", value: signedAmount(scenario.equity - invested),
                         color: .trend(scenario.equity - invested >= 0))
                }
            }
        }
    }
}
