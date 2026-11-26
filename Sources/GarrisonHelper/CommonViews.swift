import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case run = "本局", lineups = "阵容", operators = "干员", equipment = "装备", covenants = "盟约", strategies = "策略", enemies = "敌人", history = "战绩", settings = "设置"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .run: "scope"
        case .lineups: "square.stack.3d.up"
        case .history: "list.number"
        case .operators: "person.3"
        case .equipment: "shield.lefthalf.filled"
        case .covenants: "link"
        case .strategies: "lightbulb"
        case .enemies: "exclamationmark.triangle"
        case .settings: "gearshape"
        }
    }
}

struct RootView: View {
    @EnvironmentObject var catalog: Catalog
    @AppStorage("tab") private var tab: Tab = .run

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(Tab.allCases) { t in
                    Button { tab = t } label: {
                        VStack(spacing: 2) {
                            Image(systemName: t.symbol).font(.system(size: 14))
                            Text(t.rawValue).font(.system(size: 10))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                        .background(tab == t ? Color.accentColor.opacity(0.18) : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(tab == t ? Color.accentColor : .secondary)
                }
            }
            .padding(6)
            Divider()
            if let err = catalog.loadError {
                Text("数据加载失败：\(err)").foregroundStyle(.red).font(.caption).padding()
            }
            Group {
                switch tab {
                case .run: RunView()
                case .lineups: LineupLibraryView()
                case .history: HistoryView()
                case .operators: OperatorListView()
                case .equipment: EquipmentListView()
                case .covenants: CovenantListView()
                case .strategies: StrategyListView()
                case .enemies: EnemyListView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct IconView: View {
    @EnvironmentObject var catalog: Catalog
    let path: String
    var size: CGFloat = 36
    var body: some View {
        Group {
            if let img = catalog.image(path) {
                Image(nsImage: img).resizable().interpolation(.high).scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 4).fill(.quaternary)
            }
        }
        .frame(width: size, height: size)
    }
}

struct TierBadge: View {
    let tier: Int
    var body: some View {
        Text("\(tier)阶")
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(TierBadge.color(tier).opacity(0.85))
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
    static func color(_ t: Int) -> Color {
        switch t {
        case 1: .gray
        case 2: .green
        case 3: .blue
        case 4: .purple
        case 5: .orange
        default: .red
        }
    }
}

struct CovenantChip: View {
    @EnvironmentObject var catalog: Catalog
    @EnvironmentObject var run: RunState
    let name: String
    var body: some View {
        let banned = run.bannedCovenants.contains(name)
        HStack(spacing: 2) {
            IconView(path: "icons/covenants/\(name).png", size: 13)
            Text(name).font(.system(size: 11))
        }
        .padding(.horizontal, 4).padding(.vertical, 1)
        .background((catalog.covenant(named: name)?.isCore ?? false ? Color.orange : Color.teal).opacity(banned ? 0.06 : 0.15))
        .clipShape(Capsule())
        .opacity(banned ? 0.45 : 1)
        .strikethrough(banned)
        .help(banned ? "本局禁用" : name)
    }
}

/// A selectable tag for filter bars.
struct FilterTag: View {
    let title: String
    let on: Bool
    var icon: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                if let icon { IconView(path: icon, size: 13) }
                Text(title).font(.system(size: 11))
            }
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(on ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.12))
            .foregroundColor(on ? .white : .primary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Simple wrapping layout.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > maxW, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing
            widest = max(widest, x)
            rowH = max(rowH, sz.height)
        }
        return CGSize(width: min(maxW, widest), height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}

struct SectionHeader: View {
    let title: String
    var trailing: AnyView? = nil
    var body: some View {
        HStack {
            Text(title).font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
            Spacer()
            trailing
        }
    }
}

/// Removes PRTS rich-text markup like <$ba.stun>晕眩</> while keeping <回合开始时>-style triggers.
func stripMarkup(_ s: String) -> String {
    s.replacingOccurrences(of: #"<[@$][^>]*>"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: "</>", with: "")
}
