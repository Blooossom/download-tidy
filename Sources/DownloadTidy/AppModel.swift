import AppKit
import SwiftUI
import TidyCore

@MainActor
final class AppModel: ObservableObject {
    @Published var root: URL
    @Published var entries: [FileEntry] = []
    @Published var category: FileKind?
    @Published var query = ""
    @Published var period = 0
    @Published var sort = 0
    @Published var focusID: String?
    @Published var selection = Set<String>()
    @Published var contentMatches = Set<String>()
    @Published var searching = false
    @Published var loading = false
    @Published var needsFolder = false
    @Published var working = false
    @Published var canCancel = false
    @Published var history: [MoveBatch] = []
    @Published var plans: [MovePlan] = []
    @Published var showPlan = false
    @Published var showHistory = false
    @Published var message: String?
    @Published var error: String?
    @Published var scanError: String?
    @Published var storageError: String?
    @Published var contentEnabled = true
    private var organizer: Organizer?
    private let index = ContentIndex()
    private var searchTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var timer: Timer?
    private let demo: Bool
    private var scanID = UUID()
    let journalURL: URL

    init(root: URL? = nil, storage: URL? = nil) {
        demo = root != nil
        self.root = root ?? UserDefaults.standard.url(forKey: "downloadTidyRoot") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        needsFolder = root == nil && UserDefaults.standard.url(forKey: "downloadTidyRoot") == nil
        journalURL = (storage ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DownloadTidy")).appendingPathComponent("history.json")
        do { organizer = try Organizer(journalURL: journalURL) } catch { storageError = error.localizedDescription }
        Task {
            do { try await organizer?.recover() } catch { storageError = error.localizedDescription }
            history = await organizer?.history() ?? []
            if !needsFolder { await refresh() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in guard let self, !self.working, !self.showPlan else { return }; await self.refresh(quiet: true) }
        }
    }
    var filtered: [FileEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()
        var result = entries.filter { entry in
            (category == nil || entry.kind == category) &&
            (q.isEmpty || entry.name.localizedStandardContains(q) || (contentEnabled && contentMatches.contains(entry.id))) &&
            (period == 0 || (period == 1 && Calendar.current.isDateInToday(entry.added)) ||
             (period == 2 && now.timeIntervalSince(entry.added) <= 7 * 86400) ||
             (period == 3 && now.timeIntervalSince(entry.added) > 30 * 86400))
        }
        result.sort {
            if sort == 1 { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if sort == 2 { return $0.size > $1.size }
            return $0.added > $1.added
        }
        return result
    }
    var focused: FileEntry? { entries.first { $0.id == focusID } }
    var ready: [FileEntry] { entries.filter(\.canOrganize) }
    var selected: [FileEntry] { entries.filter { selection.contains($0.id) && $0.canOrganize } }
    var fileCount: Int { entries.filter { $0.kind != .folder }.count }
    var totalSize: Int64 { entries.filter { $0.kind != .folder }.reduce(0) { $0 + $1.size } }
    func refresh(quiet: Bool = false) async {
        guard !loading && !working && !needsFolder else { return }
        loading = true
        let request = UUID(); scanID = request
        let target = root
        let result = await Task.detached { Result { try Catalog.scan(target) } }.value
        guard request == scanID else { return }
        switch result {
        case .success(let items):
            let changed = items.count != entries.count || zip(items, entries).contains { $0.id != $1.id || $0.fingerprint != $1.fingerprint || $0.exclusion != $1.exclusion }
            entries = items; scanError = nil
            selection.formIntersection(Set(items.filter(\.canOrganize).map(\.id)))
            if let focusID, !items.contains(where: { $0.id == focusID }) { self.focusID = nil }
            if changed || !quiet { search() }
        case .failure(let failure):
            entries = []; selection = []; focusID = nil; scanError = failure.localizedDescription
        }
        loading = false
    }
    func search() {
        searchTask?.cancel(); contentMatches = []
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, contentEnabled else { searching = false; return }
        searching = true
        let items = entries
        searchTask = Task {
            do { try await Task.sleep(nanoseconds: 280_000_000) } catch { return }
            let matches = await index.search(q, in: items)
            guard !Task.isCancelled else { return }
            contentMatches = matches; searching = false
        }
    }
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.message = "살펴보고 정리할 다운로드 폴더를 선택하세요."
        panel.directoryURL = root
        guard panel.runModal() == .OK, let url = panel.url else { return }
        scanID = UUID(); loading = false; needsFolder = false
        root = url.resolvingSymlinksInPath(); selection = []; focusID = nil; entries = []; query = ""; category = nil
        if !demo { UserDefaults.standard.set(root, forKey: "downloadTidyRoot") }
        Task { await refresh() }
    }
    func toggle(_ entry: FileEntry) {
        if selection.contains(entry.id) { selection.remove(entry.id) } else { selection.insert(entry.id) }
    }
    func previewSelection() {
        guard storageError == nil else { error = storageError; return }
        plans = Organizer.plans(for: selected, root: root)
        showPlan = !plans.isEmpty
    }
    func organize() {
        guard let organizer, !working else { return }
        let review = plans
        showPlan = false; working = true; canCancel = true
        operationTask = Task {
            do {
                let batch = try await organizer.execute(review)
                let moved = batch.records.filter { $0.state == .moved }.count
                let failed = batch.records.count - moved
                message = "\(moved)개 파일을 정리했어요." + (failed > 0 ? " \(failed)개는 이동하지 않았어요. 기록에서 이유를 확인하세요." : " 정리 기록에서 되돌릴 수 있어요.")
                if failed > 0 { showHistory = true }
            } catch { self.error = error.localizedDescription }
            history = await organizer.history()
            selection = []; working = false; canCancel = false
            await refresh()
        }
    }
    func cancelOperation() { operationTask?.cancel() }
    func undo(_ batch: MoveBatch) {
        guard let organizer, !working else { return }
        working = true
        Task {
            do {
                let before = batch.records.filter { $0.state == .undone }.count
                let result = try await organizer.undo(batchID: batch.id)
                let count = result.records.filter { $0.state == .undone }.count - before
                message = "\(count)개 파일을 원래 위치로 되돌렸어요."
            } catch { self.error = error.localizedDescription }
            history = await organizer.history(); working = false
            await refresh()
        }
    }
    func open(_ entry: FileEntry) {
        if !NSWorkspace.shared.open(entry.url) { error = "파일을 열 수 없습니다. 연결된 앱과 파일 위치를 확인해 주세요." }
    }
    func reveal(_ entry: FileEntry) { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
}

func bytes(_ size: Int64) -> String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
