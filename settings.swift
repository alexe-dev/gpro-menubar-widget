import SwiftUI

/// Everything the widget can be told, in one sheet. Values go straight into the same
/// UserDefaults the menu bar reads, so a change lands on the next refresh.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var model = DashboardModel.shared

    @State private var primary = symbol
    @State private var secondary = symbol2
    @State private var third = symbol3
    @State private var computeAccount = computeFromExport
    @State private var deposits = String(format: "%.2f", depositsTotal)
    @State private var withdrawals = String(format: "%.2f", withdrawalsTotal)
    @State private var targets: [String: String] = takeProfit.mapValues { String(format: "%g", $0) }
    @State private var russian = Lang.current == .ru
    @State private var percentInTitle = showPercent

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("Symbols") {
                        labelled("Primary") { TextField("GPRO", text: $primary).textFieldStyle(.roundedBorder) }
                        labelled("Secondary") { TextField("KOD", text: $secondary).textFieldStyle(.roundedBorder) }
                        labelled("Third") { TextField("optional", text: $third).textFieldStyle(.roundedBorder) }
                    }

                    section("Account") {
                        Toggle("Compute from Yahoo prices", isOn: $computeAccount)
                        Text("Off: only what the open Trading 212 tab reports. On: positions.json and live quotes, so the figures keep moving outside the session.")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }

                    section("Take profit") {
                        ForEach(model.positions, id: \.symbol) { position in
                            labelled(position.symbol) {
                                TextField(String(format: "%.2f", position.avgPrice),
                                          text: binding(for: position.symbol))
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                        Text("The price a position closes at — the bid for a long.")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }

                    section("Deposits") {
                        labelled("Deposited") { TextField("0.00", text: $deposits).textFieldStyle(.roundedBorder) }
                        labelled("Withdrawn") { TextField("0.00", text: $withdrawals).textFieldStyle(.roundedBorder) }
                        Text("Totals from the platform's History screen — a CFD export cannot see transfers from Invest.")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }

                    section("Menu bar") {
                        Toggle("Show percentages", isOn: $percentInTitle)
                        Toggle("Russian interface", isOn: $russian)
                    }

                    section("Positions file") {
                        Text(model.positions.isEmpty
                             ? "positions.json not loaded"
                             : "\(model.positions.count) symbols, \(model.positions.map(\.lots).reduce(0, +)) lots")
                            .font(.system(size: 11))
                        Text("Regenerate with tools/t212-positions.py after opening or closing positions.")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 420, height: 560)
    }

    private func binding(for ticker: String) -> Binding<String> {
        Binding(get: { targets[ticker] ?? "" }, set: { targets[ticker] = $0 })
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(.tertiary)
            content()
        }
    }

    private func labelled(_ label: String, @ViewBuilder field: () -> some View) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).frame(width: 90, alignment: .leading)
            field()
        }
    }

    private func number(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00a0}", with: "")
            .replacingOccurrences(of: ",", with: "."))
    }

    private func save() {
        let newPrimary = primary.trimmingCharacters(in: .whitespaces).uppercased()
        let newSecondary = secondary.trimmingCharacters(in: .whitespaces).uppercased()
        if !newPrimary.isEmpty { symbol = newPrimary }
        if !newSecondary.isEmpty { symbol2 = newSecondary }
        symbol3 = third.trimmingCharacters(in: .whitespaces).uppercased()
        computeFromExport = computeAccount

        depositsTotal = number(deposits).map(abs) ?? 0
        withdrawalsTotal = number(withdrawals).map(abs) ?? 0
        takeProfit = targets.compactMapValues { number($0) }.filter { $0.value > 0 }
        showPercent = percentInTitle
        Lang.current = russian ? .ru : .en

        NotificationCenter.default.post(name: .settingsChanged, object: nil)
        dismiss()
    }
}

extension Notification.Name {
    static let settingsChanged = Notification.Name("gpro.settingsChanged")
}
