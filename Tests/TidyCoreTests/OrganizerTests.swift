import Testing
import Foundation
@testable import TidyCore

@Suite(.serialized)
final class OrganizerTests {
    private var cleanup: [URL] = []
    deinit { for url in cleanup { try? FileManager.default.removeItem(at: url) } }
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("download-tidy-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        cleanup.append(root)
        return root
    }
    @discardableResult
    private func file(_ root: URL, _ name: String, _ content: String = "sample") throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -10)], ofItemAtPath: url.path)
        return url
    }
    private func organizer(_ root: URL) throws -> Organizer { try Organizer(journalURL: root.appendingPathComponent(".state/history.json")) }

    @Test func testClassificationAndReadOnlyScan() throws {
        let root = try fixture()
        for name in ["photo.JPG", "report.hwpx", "archive.zip", "setup.dmg", "clip.mp4", "music.flac", "unknown.xyz", "partial.zip.crdownload", "~$locked.xlsx", ".hidden.txt"] { try file(root, name) }
        let nested = root.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try file(nested, "inside.pdf")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.pdf"), withDestinationURL: root.appendingPathComponent("photo.JPG"))
        let entries = try Catalog.scan(root)
        let plans = Organizer.plans(for: entries, root: root)
        expectEqual(plans.count, 6)
        expectEqual(entries.first { $0.name == "report.hwpx" }?.kind, .document)
        expectFalse(entries.contains { $0.name == "inside.pdf" || $0.name == "link.pdf" || $0.name == ".hidden.txt" })
        expectFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("문서").path))
        expectTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("photo.JPG").path))
    }
    @Test func testMovePersistAndUndoWithoutOverwrite() async throws {
        let root = try fixture()
        let original = try file(root, "report.txt", "important original")
        let directory = root.appendingPathComponent("문서")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let occupied = try file(directory, "report.txt", "existing file")
        let plans = Organizer.plans(for: try Catalog.scan(root), root: root)
        expectEqual(plans.count, 1)
        expectEqual(plans[0].destination.lastPathComponent, "report (1).txt")
        let store = try organizer(root)
        let batch = try await store.execute(plans)
        expectEqual(batch.records[0].state, .moved)
        expectEqual(try String(contentsOf: occupied, encoding: .utf8), "existing file")
        expectFalse(FileManager.default.fileExists(atPath: original.path))
        let organized = try Catalog.scan(root).first { $0.url.standardizedFileURL.path == plans[0].destination.standardizedFileURL.path }
        expectEqual(organized?.organized, true)
        expectEqual(organized?.canOrganize, false)
        let reopened = try organizer(root)
        let persisted = await reopened.history()
        expectEqual(persisted.count, 1)
        let undo = try await reopened.undo(batchID: batch.id)
        expectEqual(undo.records[0].state, .undone)
        expectEqual(try String(contentsOf: original, encoding: .utf8), "important original")
        let twice = try await reopened.undo(batchID: batch.id)
        expectEqual(twice.records[0].state, .undone)
    }
    @Test func testStaleSourceAndLateCollisionAreSkipped() async throws {
        let root = try fixture()
        try file(root, "one.txt"); try file(root, "two.txt"); try file(root, "three.txt")
        let plans = Organizer.plans(for: try Catalog.scan(root), root: root)
        try file(root, "one.txt", "changed after review")
        let folder = root.appendingPathComponent("문서")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try file(folder, "two.txt", "late collision")
        let result = try await organizer(root).execute(plans)
        expectEqual(result.records.filter { $0.state == .moved }.count, 1)
        expectEqual(result.records.filter { $0.state == .failed }.count, 2)
        expectEqual(try String(contentsOf: folder.appendingPathComponent("two.txt"), encoding: .utf8), "late collision")
        expectTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("one.txt").path))
    }
    @Test func testUndoProtectsChangedFilesAndOccupiedOriginals() async throws {
        let root = try fixture()
        try file(root, "one.txt"); try file(root, "two.txt")
        let plans = Organizer.plans(for: try Catalog.scan(root), root: root)
        let store = try organizer(root)
        let moved = try await store.execute(plans)
        try file(root, "one.txt", "new original")
        try file(root.appendingPathComponent("문서"), "two.txt", "edited after move")
        let undone = try await store.undo(batchID: moved.id)
        expectTrue(undone.records.allSatisfy { $0.state == .moved && $0.note != nil })
        expectEqual(try String(contentsOf: root.appendingPathComponent("one.txt"), encoding: .utf8), "new original")
        expectEqual(try String(contentsOf: root.appendingPathComponent("문서/two.txt"), encoding: .utf8), "edited after move")
    }
    @Test func testSymlinkDestinationCannotEscapeRoot() async throws {
        let root = try fixture(); let outside = try fixture()
        try file(root, "one.txt")
        let plans = Organizer.plans(for: try Catalog.scan(root), root: root)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("문서"), withDestinationURL: outside)
        let result = try await organizer(root).execute(plans)
        expectEqual(result.records[0].state, .failed)
        expectTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }
    @Test func testJournalFailurePreventsMoving() async throws {
        let root = try fixture()
        let source = try file(root, "one.txt")
        let block = try file(root, "not-a-directory")
        let store = try Organizer(journalURL: block.appendingPathComponent("history.json"))
        do { _ = try await store.execute(Organizer.plans(for: try Catalog.scan(root), root: root)); fail("Must fail before moving") } catch {}
        expectTrue(FileManager.default.fileExists(atPath: source.path))
    }
    @Test func testCorruptJournalIsPreserved() throws {
        let root = try fixture()
        let journal = try file(root, "history.json", "broken-data")
        expectThrows(try Organizer(journalURL: journal))
        expectEqual(try String(contentsOf: journal, encoding: .utf8), "broken-data")
    }
    @Test func testInterruptedMoveAndUndoRecovery() async throws {
        let root = try fixture()
        try file(root, "one.txt")
        let plan = Organizer.plans(for: try Catalog.scan(root), root: root)[0]
        try FileManager.default.createDirectory(at: plan.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: plan.source, to: plan.destination)
        let journal = root.appendingPathComponent("history.json")
        let interrupted = MoveBatch(id: UUID(), date: Date(), records: [MoveRecord(plan: plan, state: .pending)])
        try JSONEncoder().encode([interrupted]).write(to: journal)
        let store = try Organizer(journalURL: journal)
        try await store.recover()
        let recovered = await store.history()
        expectEqual(recovered[0].records[0].state, .moved)
        try FileManager.default.moveItem(at: plan.destination, to: plan.source)
        let undoing = MoveBatch(id: interrupted.id, date: Date(), records: [MoveRecord(plan: plan, state: .undoing)])
        try JSONEncoder().encode([undoing]).write(to: journal)
        let restarted = try Organizer(journalURL: journal)
        try await restarted.recover()
        let restored = await restarted.history()
        expectEqual(restored[0].records[0].state, .undone)
    }
    @Test func testContentSearchAndKoreanNormalization() async throws {
        let root = try fixture()
        let decomposed = "견적서.txt".decomposedStringWithCanonicalMapping
        try file(root, decomposed, "프로젝트 예산은 삼백만원입니다.")
        let entries = try Catalog.scan(root)
        expectTrue(entries[0].name.localizedStandardContains("견적서"))
        let index = ContentIndex()
        let result = await index.search("삼백만원", in: entries)
        expectEqual(result, Set(entries.map(\.id)))
        try file(root, decomposed, "내용을 수정했습니다.")
        let changed = await index.search("삼백만원", in: try Catalog.scan(root))
        expectTrue(changed.isEmpty)
    }
    @Test func testDownloadAndRecentFileNotPlanned() throws {
        let root = try fixture()
        try file(root, "file.pdf.part")
        let recent = root.appendingPathComponent("recent.txt")
        try Data("still downloading".utf8).write(to: recent)
        let entries = try Catalog.scan(root)
        expectTrue(Organizer.plans(for: entries, root: root).isEmpty)
    }
    @Test func testCustomFolderPreviewMoveSearchAndUndoAfterRestart() async throws {
        let root = try fixture()
        try file(root, "budget.txt", "custom folder search token")
        try file(root, "photo.png")
        try file(root, "unknown.xyz")
        let plans = try Organizer.plans(for: Catalog.scan(root), root: root, folderName: "  10월 프로젝트  ")
        let folder = root.appendingPathComponent("10월 프로젝트")
        expectEqual(plans.count, 3)
        expectTrue(plans.allSatisfy { $0.destination.deletingLastPathComponent().path == folder.path })
        expectFalse(Organizer.exists(folder))
        let result = try await organizer(root).execute(plans)
        expectTrue(result.records.allSatisfy { $0.state == .moved })
        let restarted = try organizer(root)
        let history = await restarted.history()
        let names = Organizer.managedFolderNames(in: history, root: root)
        expectEqual(names, Set(["10월 프로젝트"]))
        expectTrue(Organizer.managedFolderNames(in: history, root: try fixture()).isEmpty)
        let entries = try Catalog.scan(root, organizedFolders: names)
        expectEqual(entries.filter(\.organized).count, 3)
        expectFalse(entries.filter(\.organized).contains { $0.canOrganize })
        let matches = await ContentIndex().search("search token", in: entries)
        expectEqual(matches.count, 1)
        let restored = try await restarted.undo(batchID: result.id)
        expectTrue(restored.records.allSatisfy { $0.state == .undone })
        expectTrue(Organizer.exists(root.appendingPathComponent("budget.txt")))
        expectTrue(Organizer.exists(root.appendingPathComponent("photo.png")))
        expectTrue(Organizer.exists(root.appendingPathComponent("unknown.xyz")))
    }
    @Test func testCustomExistingFolderPreservesNameCollision() async throws {
        let root = try fixture()
        try file(root, "report.txt", "incoming")
        let folder = root.appendingPathComponent("내 자료")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let existing = try file(folder, "report.txt", "keep me")
        let plans = try Organizer.plans(for: Catalog.scan(root), root: root, folderName: "내 자료")
        expectEqual(plans[0].destination.lastPathComponent, "report (1).txt")
        let result = try await organizer(root).execute(plans)
        expectEqual(result.records[0].state, .moved)
        expectEqual(try String(contentsOf: existing, encoding: .utf8), "keep me")
    }
    @Test func testInvalidCustomNamesCannotCreateOrEscapeFolders() throws {
        let root = try fixture()
        try file(root, "report.txt")
        let entries = try Catalog.scan(root)
        for name in ["", "  ", ".", "..", "../outside", "nested/folder", "/tmp/escape", ".hidden", "a:b", "a\\b", "a\nb", "a\u{0}b", "Test.app", String(repeating: "가", count: 100)] {
            expectThrows(try Organizer.plans(for: entries, root: root, folderName: name))
        }
        expectEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["report.txt"])
    }
    @Test func testCustomFolderRejectsFilesAndLinks() throws {
        let root = try fixture(); let outside = try fixture()
        try file(root, "occupied")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: outside)
        expectThrows(try Organizer.destinationFolder(named: "occupied", root: root))
        expectThrows(try Organizer.destinationFolder(named: "linked", root: root))
    }
    @Test func testCustomDestinationChangedToLinkAfterPreviewIsSkipped() async throws {
        let root = try fixture(); let outside = try fixture()
        let source = try file(root, "report.txt")
        let plans = try Organizer.plans(for: Catalog.scan(root), root: root, folderName: "project")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("project"), withDestinationURL: outside)
        let result = try await organizer(root).execute(plans)
        expectEqual(result.records[0].state, .failed)
        expectTrue(Organizer.exists(source))
        expectTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }
    @Test func testCustomFolderUnderPrivateTmpBeforeDirectoryExists() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/jupjup-regression-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        cleanup.append(root)
        try file(root, "memo.txt")
        let plans = try Organizer.plans(for: Catalog.scan(root), root: root, folderName: "가을 프로젝트")
        let result = try await organizer(root).execute(plans)
        expectEqual(result.records[0].state, .moved)
        expectTrue(Organizer.exists(root.appendingPathComponent("가을 프로젝트/memo.txt")))
    }
    @Test func testAutomaticRulesMoveOnlyEligibleFilesAndUndo() async throws {
        let root = try fixture()
        for name in ["report.txt", "photo.png", "setup.dmg", "unknown.xyz", "partial.crdownload"] { try file(root, name) }
        let recent = try file(root, "fresh.txt")
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: recent.path)
        let arranged = root.appendingPathComponent("문서")
        try FileManager.default.createDirectory(at: arranged, withIntermediateDirectories: true)
        try file(arranged, "already.txt")
        var rules = AutomaticRule.defaults
        rules[0].folderName = "업무 자료"
        rules[1].folderName = "업무 자료"
        rules[rules.firstIndex { $0.kind == .installer }!].enabled = false
        let entries = try Catalog.scan(root)
        let plans = try AutomaticOrganization.plans(for: entries, root: root, rules: rules)
        expectEqual(Set(plans.map { $0.source.lastPathComponent }), ["report.txt", "photo.png"])
        expectFalse(Organizer.exists(root.appendingPathComponent("업무 자료")))
        let store = try organizer(root)
        let batch = try await store.execute(plans)
        expectEqual(batch.records.filter { $0.state == .moved }.count, 2)
        for name in ["setup.dmg", "unknown.xyz", "partial.crdownload", "fresh.txt", "문서/already.txt"] {
            expectTrue(Organizer.exists(root.appendingPathComponent(name)))
        }
        let reloaded = try organizer(root)
        let history = await reloaded.history()
        let rescanned = try Catalog.scan(root, organizedFolders: Organizer.managedFolderNames(in: history, root: root))
        // After a rerun only the freshly written file can become eligible; moved files never do.
        let rerun = try AutomaticOrganization.plans(for: rescanned, root: root, rules: rules)
        expectFalse(rerun.contains { ["report.txt", "photo.png"].contains($0.source.lastPathComponent) })
        let undone = try await reloaded.undo(batchID: batch.id)
        expectEqual(undone.records.filter { $0.state == .undone }.count, 2)
    }
    @Test func testAutomaticRulesPersistenceAndFolderIsolation() throws {
        let root = try fixture(); let other = try fixture()
        let url = root.appendingPathComponent(".state/rules.json")
        var store = AutomaticRuleStore()
        var rules = AutomaticRule.defaults
        rules[0].folderName = "내 문서"
        rules[1].enabled = false
        try store.save(rules, for: root, to: url)
        let reloaded = try AutomaticRuleStore.load(from: url)
        expectEqual(reloaded.rules(for: root), rules)
        expectEqual(reloaded.rules(for: other), AutomaticRule.defaults)
        expectFalse(Organizer.exists(root.appendingPathComponent("내 문서")))
        try Data("broken".utf8).write(to: url)
        expectThrows(try AutomaticRuleStore.load(from: url))
    }
    @Test func testAutomaticRulesInvalidDestinationsAndDisabledCategories() throws {
        let root = try fixture(); let outside = try fixture()
        try file(root, "report.txt"); try file(root, "photo.png")
        let entries = try Catalog.scan(root)
        var rules = AutomaticRule.defaults
        rules[0].folderName = "../escape"
        expectThrows(try AutomaticOrganization.plans(for: entries, root: root, rules: rules))
        rules[0].enabled = false
        expectEqual(try AutomaticOrganization.plans(for: entries, root: root, rules: rules).count, 1)
        rules[0].enabled = true; rules[0].folderName = "linked"
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: outside)
        expectThrows(try AutomaticOrganization.plans(for: entries, root: root, rules: rules))
        expectThrows(try AutomaticOrganization.plans(for: entries, root: root, rules: [rules[0], rules[0]]))
        for index in rules.indices { rules[index].enabled = false }
        expectTrue(try AutomaticOrganization.plans(for: entries, root: root, rules: rules).isEmpty)
        expectTrue(Organizer.exists(root.appendingPathComponent("report.txt")))
    }
    @Test func testAutomaticExistingDestinationCollision() async throws {
        let root = try fixture()
        let folder = root.appendingPathComponent("자료")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try file(root, "report.txt", "new")
        let original = try file(folder, "report.txt", "original")
        var rules = AutomaticRule.defaults; rules[0].folderName = "자료"
        let plans = try AutomaticOrganization.plans(for: Catalog.scan(root), root: root, rules: rules)
        expectEqual(plans[0].destination.lastPathComponent, "report (1).txt")
        let batch = try await organizer(root).execute(plans)
        expectEqual(batch.records[0].state, .moved)
        expectEqual(try String(contentsOf: original, encoding: .utf8), "original")
    }

    @Test func testCustomRulePriorityFallbackAndUndo() async throws {
        let root = try fixture()
        for name in ["주간 보고_01.XLSX", "budget.xlsx", "memo.txt", "debug.log", "unknown.xyz", "주간 보고.part"] { try file(root, name) }
        let custom = [
            CustomAutomaticRule(pattern: "주간 보고", folderName: "보고서"),
            CustomAutomaticRule(condition: .fileExtension, pattern: ".xlsx, XLS", folderName: "스프레드시트"),
            CustomAutomaticRule(condition: .fileExtension, pattern: "log", folderName: "로그")
        ]
        let entries = try Catalog.scan(root)
        let plans = try AutomaticOrganization.plans(for: entries, root: root, rules: AutomaticRule.defaults, customRules: custom)
        let destinations = Dictionary(uniqueKeysWithValues: plans.map { ($0.source.lastPathComponent, $0.destination.deletingLastPathComponent().lastPathComponent) })
        expectEqual(destinations["주간 보고_01.XLSX"], "보고서")
        expectEqual(destinations["budget.xlsx"], "스프레드시트")
        expectEqual(destinations["memo.txt"], "문서")
        expectEqual(destinations["debug.log"], "로그")
        expectEqual(plans.count, 4)
        let store = try organizer(root)
        let batch = try await store.execute(plans)
        expectEqual(batch.records.filter { $0.state == .moved }.count, 4)
        let undone = try await store.undo(batchID: batch.id)
        expectEqual(undone.records.filter { $0.state == .undone }.count, 4)
        var reordered = custom; reordered.swapAt(0, 1)
        let weekly = entries.first { $0.name == "주간 보고_01.XLSX" }!
        expectEqual(AutomaticOrganization.folderName(for: weekly, rules: [], customRules: reordered), "스프레드시트")
        reordered[0].enabled = false
        expectEqual(AutomaticOrganization.folderName(for: weekly, rules: [], customRules: reordered), "보고서")
    }
    @Test func testCustomMatchingAndInvalidRules() throws {
        let root = try fixture()
        try file(root, "주간 보고_FINAL.xlsx".decomposedStringWithCanonicalMapping)
        let entry = try Catalog.scan(root)[0]
        expectTrue(CustomAutomaticRule(pattern: "주간 보고_final", folderName: "보고").matches(entry))
        expectFalse(CustomAutomaticRule(pattern: "주간보고", folderName: "보고").matches(entry))
        expectFalse(CustomAutomaticRule(condition: .fileExtension, pattern: "xls", folderName: "엑셀").matches(entry))
        for pattern in ["", " ", "*", "xlsx,", "../xlsx", "xlsx xls"] {
            let rule = CustomAutomaticRule(condition: .fileExtension, pattern: pattern, folderName: "자료")
            expectThrows(try AutomaticOrganization.validate(AutomaticRule.defaults, root: root, customRules: [rule]))
        }
        let bad = CustomAutomaticRule(pattern: "report", folderName: "../outside")
        expectThrows(try AutomaticOrganization.validate(AutomaticRule.defaults, root: root, customRules: [bad]))
        var disabled = bad; disabled.enabled = false
        try AutomaticOrganization.validate(AutomaticRule.defaults, root: root, customRules: [disabled])
    }
    @Test func testLegacySettingsMigrationAndCustomPersistence() throws {
        let root = try fixture(); let other = try fixture()
        let url = root.appendingPathComponent("rules.json")
        let legacy: [String: [String: [AutomaticRule]]] = ["folders": [root.standardizedFileURL.path: AutomaticRule.defaults]]
        try JSONEncoder().encode(legacy).write(to: url)
        var store = try AutomaticRuleStore.load(from: url)
        expectTrue(store.customRules(for: root).isEmpty)
        expectFalse(store.watchesDownloads(for: root))
        let custom = [CustomAutomaticRule(pattern: "invoice", folderName: "Invoices"), CustomAutomaticRule(condition: .fileExtension, pattern: "pdf", folderName: "PDF")]
        try store.save(AutomaticRule.defaults, for: root, to: url, customRules: custom, watchesDownloads: true)
        store = try AutomaticRuleStore.load(from: url)
        expectEqual(store.customRules(for: root), custom)
        expectTrue(store.watchesDownloads(for: root))
        expectTrue(store.customRules(for: other).isEmpty)
        expectFalse(store.watchesDownloads(for: other))
        try store.save(AutomaticRule.defaults, for: root, to: url)
        expectEqual(try AutomaticRuleStore.load(from: url).customRules(for: root), custom)
    }
    @Test func testDownloadMonitorBaselineStabilityAndUndo() async throws {
        let root = try fixture(); try file(root, "existing.txt")
        var monitor = DownloadMonitor()
        let rules = AutomaticRule.defaults
        monitor.observe(try Catalog.scan(root))
        expectTrue(monitor.candidates(in: try Catalog.scan(root), rules: rules, customRules: []).isEmpty)
        let partial = try file(root, "new.txt.crdownload")
        monitor.observe(try Catalog.scan(root))
        expectTrue(monitor.candidates(in: try Catalog.scan(root), rules: rules, customRules: []).isEmpty)
        let completed = root.appendingPathComponent("new.txt")
        try FileManager.default.moveItem(at: partial, to: completed)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: completed.path)
        monitor.observe(try Catalog.scan(root))
        expectTrue(monitor.candidates(in: try Catalog.scan(root), rules: rules, customRules: []).isEmpty)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -10)], ofItemAtPath: completed.path)
        let entries = try Catalog.scan(root); monitor.observe(entries)
        let ids = monitor.candidates(in: entries, rules: rules, customRules: [])
        expectEqual(ids, Set(entries.filter { $0.name == "new.txt" }.map(\.id)))
        monitor.consume(ids)
        let store = try organizer(root)
        let batch = try await store.execute(AutomaticOrganization.plans(for: entries.filter { ids.contains($0.id) }, root: root, rules: rules))
        monitor.observe(try Catalog.scan(root))
        _ = try await store.undo(batchID: batch.id)
        monitor.ignoreRestored(ids)
        let restored = try Catalog.scan(root); monitor.observe(restored)
        expectTrue(monitor.candidates(in: restored, rules: rules, customRules: []).isEmpty)
        expectTrue(Organizer.exists(root.appendingPathComponent("existing.txt")))
    }
    @Test func testDownloadMonitorReplacementAndNoMatch() throws {
        let root = try fixture(); let original = try file(root, "existing.txt")
        var monitor = DownloadMonitor(); monitor.observe(try Catalog.scan(root))
        try Data("edited".utf8).write(to: original)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -10)], ofItemAtPath: original.path)
        var entries = try Catalog.scan(root); monitor.observe(entries)
        expectTrue(monitor.candidates(in: entries, rules: AutomaticRule.defaults, customRules: []).isEmpty)
        try FileManager.default.moveItem(at: original, to: root.appendingPathComponent(".old"))
        try file(root, "existing.txt")
        try file(root, "new.log")
        entries = try Catalog.scan(root); monitor.observe(entries)
        expectEqual(monitor.candidates(in: entries, rules: AutomaticRule.defaults, customRules: []), Set(entries.filter { $0.name == "existing.txt" }.map(\.id)))
        let rule = CustomAutomaticRule(condition: .fileExtension, pattern: "log", folderName: "Logs")
        expectEqual(monitor.candidates(in: entries, rules: AutomaticRule.defaults, customRules: [rule]), Set(entries.map(\.id)))
        var freshSession = DownloadMonitor(); freshSession.observe(entries)
        expectTrue(freshSession.candidates(in: entries, rules: AutomaticRule.defaults, customRules: [rule]).isEmpty)
    }

}

private func expectEqual<T: Equatable>(_ a: T, _ b: T, sourceLocation: SourceLocation = #_sourceLocation) { #expect(a == b, sourceLocation: sourceLocation) }
private func expectTrue(_ value: Bool, sourceLocation: SourceLocation = #_sourceLocation) { #expect(value, sourceLocation: sourceLocation) }
private func expectFalse(_ value: Bool, sourceLocation: SourceLocation = #_sourceLocation) { #expect(!value, sourceLocation: sourceLocation) }
private func fail(_ message: String, sourceLocation: SourceLocation = #_sourceLocation) { Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation) }
private func expectThrows<T>(_ expression: @autoclosure () throws -> T, sourceLocation: SourceLocation = #_sourceLocation) {
    do { _ = try expression(); Issue.record("Expected an error", sourceLocation: sourceLocation) } catch {}
}
