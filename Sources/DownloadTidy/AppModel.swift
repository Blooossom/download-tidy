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
    @Published var useCustomFolder = false
    @Published var customFolderName = ""
    @Published var planError: String?
    @Published var destinationDescription = ""
    @Published var existingFolderNames: [String] = []
    @Published var showPlan = false
    @Published var showHistory = false
    @Published var showAutomaticSettings = false
    @Published var automaticRules = AutomaticRule.defaults
    @Published var draftRules = AutomaticRule.defaults
    @Published var automaticSettingsError: String?
    @Published var rulesStorageError: String?
    @Published var undoBatchID: UUID?
    private var ruleStore = AutomaticRuleStore()
    private let rulesURL: URL
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
    private var planEntries: [FileEntry] = []
    let journalURL: URL

    init(root: URL? = nil, storage: URL? = nil) {
        demo = root != nil
        self.root = root ?? UserDefaults.standard.url(forKey: "downloadTidyRoot") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        needsFolder = root == nil && UserDefaults.standard.url(forKey: "downloadTidyRoot") == nil
        journalURL = (storage ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DownloadTidy")).appendingPathComponent("history.json")
        rulesURL = journalURL.deletingLastPathComponent().appendingPathComponent("automatic-rules.json")
        do {
            ruleStore = try AutomaticRuleStore.load(from: rulesURL)
            automaticRules = ruleStore.rules(for: self.root)
        } catch { rulesStorageError = "자동정리 설정을 읽지 못했어요: \(error.localizedDescription)" }
        do { organizer = try Organizer(journalURL: journalURL) } catch { storageError = error.localizedDescription }
        Task {
            do { try await organizer?.recover() } catch { storageError = error.localizedDescription }
            history = await organizer?.history() ?? []
            if !needsFolder { await refresh() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in guard let self, !self.working, !self.showPlan, !self.showAutomaticSettings else { return }; await self.refresh(quiet: true) }
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
    var selected: [FileEntry] { entries.filter { selection.contains($0.id) && $0.canMove } }
    var fileCount: Int { entries.filter { $0.kind != .folder }.count }
    var totalSize: Int64 { entries.filter { $0.kind != .folder }.reduce(0) { $0 + $1.size } }
    var automaticCount: Int {
        entries.filter { entry in entry.canOrganize && automaticRules.contains { $0.kind == entry.kind && $0.enabled } }.count
    }
    var undoBatch: MoveBatch? { history.first { $0.id == undoBatchID && $0.records.contains { $0.state == .moved } } }
    var reviewCount: Int { planEntries.count }
    func selectCategory(_ kind: FileKind?) {
        guard category != kind else { return }
        category = kind
        selection = []
        if let focused, let kind, focused.kind != kind { focusID = nil }
    }
    func refresh(quiet: Bool = false) async {
        guard !loading && !working && !needsFolder else { return }
        loading = true
        let request = UUID(); scanID = request
        let target = root
        let folders = Organizer.managedFolderNames(in: history, root: target)
        let result = await Task.detached { Result { try Catalog.scan(target, organizedFolders: folders) } }.value
        guard request == scanID else { return }
        switch result {
        case .success(let items):
            let changed = items.count != entries.count || zip(items, entries).contains { $0.id != $1.id || $0.fingerprint != $1.fingerprint || $0.exclusion != $1.exclusion }
            entries = items; scanError = nil
            selection.formIntersection(Set(items.filter(\.canMove).map(\.id)))
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
        automaticRules = ruleStore.rules(for: root)
        if !demo { UserDefaults.standard.set(root, forKey: "downloadTidyRoot") }
        Task { await refresh() }
    }
    func toggle(_ entry: FileEntry) {
        if selection.contains(entry.id) { selection.remove(entry.id) } else { selection.insert(entry.id) }
    }
    func previewSelection() {
        guard storageError == nil else { error = storageError; return }
        planEntries = selected
        guard !planEntries.isEmpty else { return }
        useCustomFolder = planEntries.contains { !$0.kind.canOrganize }; customFolderName = ""
        loadFolderChoices()
        updatePlan()
        showPlan = true
    }
    func updatePlan() {
        planError = nil
        destinationDescription = ""
        do {
            if useCustomFolder {
                let folder = try Organizer.destinationFolder(named: customFolderName, root: root)
                plans = try Organizer.plans(for: planEntries, root: root, folderName: customFolderName)
                destinationDescription = Organizer.exists(folder) ? "기존 폴더에 모아요: \(folder.path)" : "이동할 때 새 폴더를 만들어요: \(folder.path)"
            } else {
                guard planEntries.allSatisfy({ $0.kind.canOrganize }) else {
                    throw TidyError.message("기타 파일이 포함되어 있어요. ‘직접 지정한 폴더’에서 모을 위치를 정해 주세요.")
                }
                plans = Organizer.plans(for: planEntries, root: root)
                destinationDescription = "파일 종류에 따라 문서·이미지·압축파일 등의 폴더로 나눠요."
            }
        } catch {
            plans = []
            planError = error.localizedDescription
        }
    }
    private func loadFolderChoices() {
        existingFolderNames = entries.filter { $0.kind == .folder && !$0.organized }
            .map(\.name).filter { (try? Organizer.destinationFolder(named: $0, root: root)) != nil }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    func editAutomaticSettings() {
        guard !working, !needsFolder else { return }
        draftRules = automaticRules
        loadFolderChoices()
        validateAutomaticSettings()
        showAutomaticSettings = true
    }
    func validateAutomaticSettings() {
        do {
            try AutomaticOrganization.validate(draftRules, root: root)
            automaticSettingsError = rulesStorageError
        } catch { automaticSettingsError = error.localizedDescription }
    }
    func saveAutomaticSettings() {
        guard !working, rulesStorageError == nil else { return }
        do {
            try ruleStore.save(draftRules, for: root, to: rulesURL)
            automaticRules = draftRules
            showAutomaticSettings = false
        } catch { automaticSettingsError = error.localizedDescription }
    }
    func automaticOrganize() {
        guard organizer != nil, !working, !loading, !needsFolder, storageError == nil else { return }
        guard rulesStorageError == nil else { error = rulesStorageError; return }
        let target = root
        let rules = automaticRules
        let folders = Organizer.managedFolderNames(in: history, root: target)
        working = true; canCancel = true; message = nil; undoBatchID = nil
        operationTask = Task {
            do {
                let items = try await Task.detached { try Catalog.scan(target, organizedFolders: folders) }.value
                try Task.checkCancellation()
                let review = try AutomaticOrganization.plans(for: items, root: target, rules: rules)
                let skipped = items.filter { !$0.organized && $0.kind != .folder }.count - review.count
                if review.isEmpty {
                    message = "자동정리할 파일이 없어요. \(skipped)개 제외 · 분류 설정과 파일 상태를 확인해 주세요."
                } else {
                    await execute(review, automaticSkipped: skipped)
                }
            } catch is CancellationError { message = "자동정리를 중단했어요." }
            catch { self.error = error.localizedDescription }
            working = false; canCancel = false
            await refresh()
        }
    }
    func organize() {
        guard organizer != nil, !working, planError == nil, !plans.isEmpty else { return }
        let review = plans
        showPlan = false; working = true; canCancel = true; message = nil; undoBatchID = nil
        operationTask = Task {
            await execute(review)
            working = false; canCancel = false
            await refresh()
        }
    }
    private func execute(_ review: [MovePlan], automaticSkipped: Int? = nil) async {
        guard let organizer else { return }
        do {
            let batch = try await organizer.execute(review)
            let moved = batch.records.filter { $0.state == .moved }.count
            let failed = batch.records.count - moved
            if let skipped = automaticSkipped {
                message = "자동정리 \(moved)개 완료 · \(skipped + failed)개 제외" + (failed > 0 ? " · 이동하지 못한 이유는 정리 기록에서 확인하세요." : " · 정리한 파일은 되돌릴 수 있어요.")
            } else {
                message = "\(moved)개 파일을 정리했어요." + (failed > 0 ? " \(failed)개는 이동하지 않았어요. 기록에서 이유를 확인하세요." : " 정리 기록에서 되돌릴 수 있어요.")
            }
            undoBatchID = moved > 0 ? batch.id : nil
            if failed > 0 { showHistory = true }
        } catch is CancellationError { message = "정리를 중단했어요." }
        catch { self.error = error.localizedDescription }
        history = await organizer.history()
        selection = []
    }
    func cancelOperation() { operationTask?.cancel() }
    func undo(_ batch: MoveBatch) {
        guard let organizer, !working else { return }
        working = true; undoBatchID = nil
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
