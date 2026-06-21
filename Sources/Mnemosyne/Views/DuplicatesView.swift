import SwiftUI

/// A one-place view to resolve EXACT duplicate files: each group shows the copies;
/// keep the one you want and remove the rest from the knowledge base (the files on
/// disk are untouched). Composed from DS tokens.
struct DuplicatesView: View {
    @Bindable var vm: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.x4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Duplicate files").font(DS.Typo.title3).foregroundStyle(DS.ColorToken.textPrimary)
                    Text("Same content, more than one copy. Remove extras from the knowledge base — the files on disk stay put.")
                        .font(DS.Typo.caption).foregroundStyle(DS.ColorToken.textTertiary)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.plain)
                    .font(DS.Typo.callout).foregroundStyle(DS.ColorToken.iris)
                    .keyboardShortcut(.cancelAction)
            }
            let groups = vm.duplicateItemGroups
            if groups.isEmpty {
                VStack(spacing: DS.Space.x2) {
                    Image(systemName: "checkmark.seal").font(.system(size: 30)).foregroundStyle(DS.ColorToken.success)
                    Text("No duplicates left.").font(DS.Typo.lead).foregroundStyle(DS.ColorToken.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.x4) {
                        ForEach(Array(groups.enumerated()), id: \.offset) { i, group in
                            groupCard(index: i + 1, group: group)
                        }
                    }
                }
            }
        }
        .padding(DS.Space.x6)
        .frame(width: 640, height: 560)
        .background(DS.ColorToken.surface)
    }

    private func groupCard(index: Int, group: [KnowledgeItem]) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.x2) {
            Text("SET \(index) · \(group.count) copies").font(DS.Typo.caption).tracking(1)
                .foregroundStyle(DS.ColorToken.textTertiary)
            ForEach(group) { item in
                HStack(spacing: DS.Space.x3) {
                    Image(systemName: item.kind.sfSymbol).font(.system(size: 12)).foregroundStyle(DS.ColorToken.iris)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).font(DS.Typo.body).foregroundStyle(DS.ColorToken.textPrimary).lineLimit(1)
                        Text(item.path).font(DS.Typo.mono).foregroundStyle(DS.ColorToken.textTertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: DS.Space.x2)
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                    } label: {
                        Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(DS.ColorToken.textTertiary)
                    }.buttonStyle(.plain).help("Reveal in Finder")
                    Button { withAnimation(DS.Motion.snappy) { vm.deleteItem(item.id) } } label: {
                        Text("Remove").font(DS.Typo.caption).foregroundStyle(DS.ColorToken.danger)
                            .padding(.horizontal, DS.Space.x3).padding(.vertical, DS.Space.x1)
                            .overlay(Capsule().strokeBorder(DS.ColorToken.danger.opacity(0.4), lineWidth: 1))
                    }.buttonStyle(.plain).help("Remove this copy from the knowledge base")
                }
                .padding(.vertical, DS.Space.x1)
            }
        }
        .padding(DS.Space.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.ColorToken.canvasRaised, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
            .strokeBorder(DS.ColorToken.borderDefault))
    }
}
