import AppKit
import Testing
import NeodiskKit
@testable import NeodiskUI

@MainActor
@Suite(.serialized)
struct OutlineKeyboardNavigationTests {
    private struct Environment {
        let cacheDirectory: URL
        let cache: ScanSnapshotCache
        let scanService = ControlledScanService()
        let sidebarFolderStore: SidebarFolderStore
        let defaults: UserDefaults
        private let defaultsSuiteName: String

        init() throws {
            cacheDirectory = FileManager.default.temporaryDirectory.appending(
                path: "NeodiskOutlineKeyboardTests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
            cache = ScanSnapshotCache(directoryURL: cacheDirectory, isLoggingEnabled: false)
            defaultsSuiteName = "NeodiskOutlineKeyboardTests-\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
            sidebarFolderStore = SidebarFolderStore(defaults: defaults)
        }

        @MainActor
        func makeModel() -> NeodiskViewModel {
            NeodiskViewModel(
                coordinator: ScanCoordinator(scanService: scanService),
                snapshotCache: cache,
                sidebarFolderStore: sidebarFolderStore
            )
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: cacheDirectory)
            removeTestDefaultsSuite(defaults, named: defaultsSuiteName)
        }
    }

    private func makeSnapshot(target: ScanTarget) -> ScanSnapshot {
        let alpha = makeTestFileNode(
            id: target.id + "/folder/alpha.txt", name: "alpha.txt", size: 50
        )
        let zeta = makeTestFileNode(
            id: target.id + "/folder/zeta.txt", name: "zeta.txt", size: 100
        )
        let folder = makeTestDirectoryNode(
            id: target.id + "/folder", name: "folder", children: [zeta, alpha]
        )
        let empty = makeTestDirectoryNode(
            id: target.id + "/empty", name: "empty", children: []
        )
        let loose = makeTestFileNode(
            id: target.id + "/loose.txt", name: "loose.txt", size: 25
        )
        let root = makeTestDirectoryNode(
            id: target.id, name: target.displayName, children: [folder, loose, empty]
        )
        let store = FileTreeStore(
            root: root,
            childrenByID: [
                root.id: [folder, loose, empty],
                folder.id: [zeta, alpha],
            ]
        )
        return makeTestSnapshot(target: target, root: root, store: store)
    }

    @Test func resolvesExpandCollapseAndParentChildMoves() throws {
        let environment = try Environment()
        defer { environment.tearDown() }
        let target = makeTestTarget("/outline/keyboard-actions")
        let model = environment.makeModel()
        model.coordinator.replaceCurrentSnapshot(makeSnapshot(target: target))

        let rootID = target.id
        let folderID = target.id + "/folder"
        let emptyID = target.id + "/empty"
        let looseID = target.id + "/loose.txt"
        let collapsedRows = model.visibleOutlineRows()
        let rootRow = try row(of: rootID, in: collapsedRows)
        let folderRow = try row(of: folderID, in: collapsedRows)
        let emptyRow = try row(of: emptyID, in: collapsedRows)
        let looseRow = try row(of: looseID, in: collapsedRows)

        #expect(action(.right, row: folderRow, rows: collapsedRows, expanded: [rootID])
            == .expand(folderID))
        #expect(action(.left, row: folderRow, rows: collapsedRows, expanded: [rootID])
            == .selectRow(rootRow))
        #expect(action(.left, row: rootRow, rows: collapsedRows, expanded: [rootID])
            == .collapse(rootID))
        #expect(action(.left, row: rootRow, rows: collapsedRows, expanded: []) == nil)
        #expect(action(.right, row: emptyRow, rows: collapsedRows, expanded: [rootID]) == nil)
        #expect(action(.right, row: looseRow, rows: collapsedRows, expanded: [rootID]) == nil)

        model.toggleExpansion(folderID)
        let expandedRows = model.visibleOutlineRows()
        let expandedFolderRow = try row(of: folderID, in: expandedRows)
        let firstChildRow = expandedFolderRow + 1

        #expect(action(
            .right, row: expandedFolderRow, rows: expandedRows,
            expanded: model.expandedNodeIDs
        ) == .selectRow(firstChildRow))
        #expect(action(
            .left, row: firstChildRow, rows: expandedRows,
            expanded: model.expandedNodeIDs
        ) == .selectRow(expandedFolderRow))
        #expect(action(
            .left, row: expandedFolderRow, rows: expandedRows,
            expanded: model.expandedNodeIDs
        ) == .collapse(folderID))
    }

    @Test func firstChildFollowsDisplayedSortOrder() throws {
        let environment = try Environment()
        defer { environment.tearDown() }
        let target = makeTestTarget("/outline/keyboard-sort")
        let model = environment.makeModel()
        model.coordinator.replaceCurrentSnapshot(makeSnapshot(target: target))
        let folderID = target.id + "/folder"
        model.toggleExpansion(folderID)

        let rows = model.visibleOutlineRows(
            sortedBy: OutlineSort(field: .name, ascending: true)
        )
        let folderRow = try row(of: folderID, in: rows)
        let resolved = action(
            .right, row: folderRow, rows: rows, expanded: model.expandedNodeIDs
        )

        #expect(resolved == .selectRow(folderRow + 1))
        #expect(rows[folderRow + 1].node.name == "alpha.txt")
    }

    @Test func performingActionsUpdatesExpansionAndSelection() throws {
        let environment = try Environment()
        defer { environment.tearDown() }
        let target = makeTestTarget("/outline/keyboard-perform")
        let model = environment.makeModel()
        model.coordinator.replaceCurrentSnapshot(makeSnapshot(target: target))
        let folderID = target.id + "/folder"

        let tableView = OutlineNSTableView()
        let coordinator = OutlineTreeTable.Coordinator(model: model)
        tableView.addTableColumn(NSTableColumn(identifier: .init("outline")))
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        coordinator.tableView = tableView
        coordinator.apply(snapshot: model.outlineRowsSnapshot())

        var rows = model.visibleOutlineRows()
        var folderRow = try row(of: folderID, in: rows)
        tableView.selectRowIndexes([folderRow], byExtendingSelection: false)
        OutlineKeyboardNavigation.perform(.right, in: tableView, rows: rows, model: model)

        #expect(model.expandedNodeIDs.contains(folderID))
        #expect(model.selectedNodeID == folderID)

        let expandedSnapshot = model.outlineRowsSnapshot()
        coordinator.apply(snapshot: expandedSnapshot)
        rows = expandedSnapshot.rows
        folderRow = try row(of: folderID, in: rows)
        tableView.selectRowIndexes([folderRow], byExtendingSelection: false)
        OutlineKeyboardNavigation.perform(.right, in: tableView, rows: rows, model: model)

        #expect(tableView.selectedRow == folderRow + 1)
        #expect(model.selectedNodeID == rows[folderRow + 1].id)

        OutlineKeyboardNavigation.perform(.left, in: tableView, rows: rows, model: model)
        #expect(tableView.selectedRow == folderRow)
        #expect(model.selectedNodeID == folderID)

        OutlineKeyboardNavigation.perform(.left, in: tableView, rows: rows, model: model)
        #expect(!model.expandedNodeIDs.contains(folderID))
        #expect(model.selectedNodeID == folderID)
    }

    @Test func parentJumpScrollsOffscreenParentIntoView() throws {
        let environment = try Environment()
        defer { environment.tearDown() }
        let target = makeTestTarget("/outline/keyboard-reveal")
        let model = environment.makeModel()
        model.coordinator.replaceCurrentSnapshot(makeSnapshot(target: target))
        let folderID = target.id + "/folder"
        model.toggleExpansion(folderID)

        let tableView = OutlineNSTableView()
        let coordinator = OutlineTreeTable.Coordinator(model: model)
        tableView.addTableColumn(NSTableColumn(identifier: .init("outline")))
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        coordinator.tableView = tableView

        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 200, height: 30)
        )
        scrollView.documentView = tableView
        coordinator.scrollView = scrollView

        let snapshot = model.outlineRowsSnapshot()
        coordinator.apply(snapshot: snapshot)
        scrollView.layoutSubtreeIfNeeded()

        let rows = snapshot.rows
        let folderRow = try row(of: folderID, in: rows)
        let lastChildRow = folderRow + 2
        #expect(rows[lastChildRow].depth == rows[folderRow].depth + 1)
        tableView.selectRowIndexes([lastChildRow], byExtendingSelection: false)

        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: tableView.rect(ofRow: lastChildRow).minY))
        scrollView.reflectScrolledClipView(clip)
        #expect(!clip.bounds.intersects(tableView.rect(ofRow: folderRow)))

        coordinator.navigateHierarchy(.left)

        #expect(tableView.selectedRow == folderRow)
        let folderRect = tableView.rect(ofRow: folderRow)
        #expect(clip.bounds.minY <= folderRect.minY)
        #expect(folderRect.maxY <= clip.bounds.maxY)
    }

    @Test func tableRoutesOnlyUnmodifiedHorizontalArrows() throws {
        let tableView = OutlineNSTableView()
        var received: [OutlineHierarchyDirection] = []
        tableView.hierarchyNavigationRequested = { received.append($0) }

        tableView.keyDown(with: try arrowEvent(.left))
        tableView.keyDown(with: try arrowEvent(.right))
        #expect(received == [.left, .right])

        tableView.keyDown(with: try arrowEvent(.right, modifiers: .command))
        #expect(received == [.left, .right])
    }

    private func action(
        _ direction: OutlineHierarchyDirection,
        row: Int,
        rows: [NeodiskViewModel.OutlineRow],
        expanded: Set<String>
    ) -> OutlineHierarchyAction? {
        OutlineKeyboardNavigation.action(
            for: direction, selectedRow: row, rows: rows, expandedNodeIDs: expanded
        )
    }

    private func row(
        of nodeID: String, in rows: [NeodiskViewModel.OutlineRow]
    ) throws -> Int {
        try #require(rows.firstIndex { $0.id == nodeID })
    }

    private func arrowEvent(
        _ direction: OutlineHierarchyDirection,
        modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        let characters: String
        let keyCode: UInt16
        switch direction {
        case .left:
            characters = "\u{F702}"
            keyCode = 123
        case .right:
            characters = "\u{F703}"
            keyCode = 124
        }
        return try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
    }
}
