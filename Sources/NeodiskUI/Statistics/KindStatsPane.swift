//
//  KindStatsPane.swift
//  Neodisk
//
//  The statistics panel's Kinds tab: one row per file kind with its treemap
//  color, total size, and file count, largest first. Right-clicking a type
//  moves it to another category (or a new one); right-clicking a category
//  the user made renames or deletes it.
//

import SwiftUI
import NeodiskKit
import NeodiskAppModel

struct KindStatsPane: View {
    let model: NeodiskViewModel
    @State private var namePrompt: CategoryNamePrompt?
    @State private var promptedName = ""

    var body: some View {
        if model.kinds.drill.isActive {
            @Bindable var drill = model.kinds.drill
            StatsFileListView(
                model: model,
                title: model.kinds.drill.context?.kind.displayName,
                swatch: model.kinds.drill.context.map { context in
                    Color(rgb: model.kinds.catalog.rgb(forKindID: context.kind.id))
                },
                backHelp: "Back to file kinds",
                isLoading: model.kinds.drill.isLoading,
                visibleIDs: model.kinds.drill.visibleIDs,
                totalMatches: model.kinds.drill.totalMatches,
                filterText: $drill.filterText,
                onClose: { model.kinds.closeFileList() }
            )
        } else {
            kindStatsList
        }
    }

    private var kindStatsList: some View {
        @Bindable var kinds = model.kinds
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Group by")
                    .neoFont(11, weight: .semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $kinds.displayMode) {
                    ForEach(FileKindDisplayMode.allCases) { mode in
                        Text(LocalizedStringKey(mode.title)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .neoControlSize(base: .small)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)

            Divider()

            if model.kinds.catalog.stats.isEmpty || model.kinds.catalog.mode != model.kinds.displayMode {
                // Either nothing built yet, or the user just switched modes
                // and the catalog for the new mode is still building — don't
                // show the stale list.
                Spacer()
                ProgressView().neoControlSize(base: .small)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(model.kinds.catalog.stats) { stat in
                    StatsLegendRow(
                        swatch: stat.color,
                        name: LocalizedStringKey(stat.kind.displayName),
                        fileCount: stat.fileCount,
                        totalAllocatedSize: stat.totalAllocatedSize,
                        totalSize: totalSize
                    )
                    .listRowSeparator(.hidden)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.kinds.openFileList(for: stat)
                    }
                    .help("Show every file of this kind")
                    .contextMenu { categoryMenu(for: stat.kind) }
                }
                .environment(\.defaultMinListRowHeight, 20)
            }
        }
        .alert(
            namePrompt?.title ?? "",
            isPresented: Binding(get: { namePrompt != nil }, set: { if !$0 { namePrompt = nil } }),
            presenting: namePrompt
        ) { prompt in
            TextField("Name", text: $promptedName)
            Button("Cancel", role: .cancel) {}
            Button(prompt.confirmTitle) { commit(prompt) }
        }
    }

    // MARK: - Categories

    @ViewBuilder
    private func categoryMenu(for kind: FileKind) -> some View {
        let rules = FileCategoryRules.current
        switch model.kinds.catalog.mode {
        case .types where FileCategoryRules.isAssignableTypeID(kind.id):
            Picker("Category", selection: Binding(
                get: { rules.categoryID(forExtension: kind.id) },
                set: { categoryID in
                    model.updateFileCategories { $0.assign(extension: kind.id, to: categoryID) }
                }
            )) {
                ForEach(rules.assignableCategories) { category in
                    Text(LocalizedStringKey(category.displayName)).tag(category.id)
                }
            }
            Button("New Category…") {
                promptedName = ""
                namePrompt = .newCategory(extension: kind.id)
            }
            if rules.isOverridden(extension: kind.id) {
                Button("Use Default Category") {
                    model.updateFileCategories {
                        $0.assign(extension: kind.id, to: FileCategoryRules.builtInCategoryID(forExtension: kind.id))
                    }
                }
            }
        case .categories where rules.customKindsByID[kind.id] != nil:
            Button("Rename Category…") {
                promptedName = kind.displayName
                namePrompt = .rename(categoryID: kind.id)
            }
            Button("Delete Category", role: .destructive) {
                model.updateFileCategories { $0.removeCategory(id: kind.id) }
            }
        default:
            EmptyView()
        }
    }

    private func commit(_ prompt: CategoryNamePrompt) {
        let name = promptedName
        switch prompt {
        case .newCategory(let ext):
            model.updateFileCategories { customization in
                guard let id = customization.addCategory(named: name) else { return }
                customization.assign(extension: ext, to: id)
            }
        case .rename(let categoryID):
            model.updateFileCategories { $0.renameCategory(id: categoryID, to: name) }
        }
    }

    private var totalSize: Int64 {
        model.coordinator.snapshot?.aggregateStats.totalAllocatedSize ?? 0
    }
}

/// The name a category menu item asks for.
private enum CategoryNamePrompt {
    case newCategory(extension: String)
    case rename(categoryID: String)

    var title: LocalizedStringKey {
        switch self {
        case .newCategory: return "New Category"
        case .rename: return "Rename Category"
        }
    }

    var confirmTitle: LocalizedStringKey {
        switch self {
        case .newCategory: return "Create"
        case .rename: return "Rename"
        }
    }
}
