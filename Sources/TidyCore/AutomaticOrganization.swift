import Foundation

public struct AutomaticRule: Codable, Equatable, Sendable {
    public let kind: FileKind
    public var enabled: Bool
    public var folderName: String

    public static var defaults: [Self] {
        FileKind.allCases.filter(\.canOrganize).map { Self(kind: $0, enabled: true, folderName: $0.rawValue) }
    }
}

public enum CustomRuleCondition: String, CaseIterable, Codable, Sendable {
    case filenameContains, fileExtension
    public var label: String { self == .filenameContains ? "파일명에 포함" : "확장자" }
}

public struct CustomAutomaticRule: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var enabled: Bool
    public var condition: CustomRuleCondition
    public var pattern: String
    public var folderName: String
    public init(id: UUID = UUID(), enabled: Bool = true, condition: CustomRuleCondition = .filenameContains,
                pattern: String = "", folderName: String = "") {
        self.id = id; self.enabled = enabled; self.condition = condition
        self.pattern = pattern; self.folderName = folderName
    }
    private var extensions: [String] {
        pattern.split(separator: ",", omittingEmptySubsequences: false).map {
            let value = $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return value.hasPrefix(".") ? String(value.dropFirst()) : value
        }
    }
    public func validate() throws {
        guard !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TidyError.message("조건을 입력해 주세요.")
        }
        if condition == .fileExtension {
            guard extensions.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) } }) else {
                throw TidyError.message("확장자는 xlsx 또는 xlsx, xls처럼 입력해 주세요.")
            }
        }
    }
    public func matches(_ entry: FileEntry) -> Bool {
        guard enabled, (try? validate()) != nil else { return false }
        switch condition {
        case .filenameContains:
            let needle = pattern.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
            return entry.name.precomposedStringWithCanonicalMapping.range(of: needle, options: .caseInsensitive) != nil
        case .fileExtension:
            return extensions.contains(entry.url.pathExtension.lowercased())
        }
    }
}

/// Rules belong to the selected root, so changing folders never reuses another folder's choices.
public struct AutomaticRuleStore: Codable, Sendable {
    private var folders: [String: [AutomaticRule]] = [:]
    private var customFolders: [String: [CustomAutomaticRule]] = [:]
    private var watchedFolders: [String: Bool] = [:]
    private enum CodingKeys: String, CodingKey { case folders, customFolders, watchedFolders }
    public init() {}
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        folders = try values.decode([String: [AutomaticRule]].self, forKey: .folders)
        customFolders = try values.decodeIfPresent([String: [CustomAutomaticRule]].self, forKey: .customFolders) ?? [:]
        watchedFolders = try values.decodeIfPresent([String: Bool].self, forKey: .watchedFolders) ?? [:]
    }
    public static func load(from url: URL) throws -> Self {
        guard Organizer.exists(url) else { return Self() }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
    public func rules(for root: URL) -> [AutomaticRule] {
        folders[root.standardizedFileURL.path] ?? AutomaticRule.defaults
    }
    public func customRules(for root: URL) -> [CustomAutomaticRule] {
        customFolders[root.standardizedFileURL.path] ?? []
    }
    public func watchesDownloads(for root: URL) -> Bool { watchedFolders[root.standardizedFileURL.path] ?? false }
    public mutating func save(_ rules: [AutomaticRule], for root: URL, to url: URL, customRules: [CustomAutomaticRule]? = nil, watchesDownloads: Bool? = nil) throws {
        let custom = customRules ?? self.customRules(for: root)
        try AutomaticOrganization.validate(rules, root: root, customRules: custom)
        var updated = self
        updated.folders[root.standardizedFileURL.path] = rules
        updated.customFolders[root.standardizedFileURL.path] = custom
        updated.watchedFolders[root.standardizedFileURL.path] = watchesDownloads ?? self.watchesDownloads(for: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(updated).write(to: url, options: .atomic)
        self = updated
    }
}

public enum AutomaticOrganization {
    public static func validate(_ rules: [AutomaticRule], root: URL, customRules: [CustomAutomaticRule] = []) throws {
        let kinds = rules.map(\.kind)
        guard kinds.count == AutomaticRule.defaults.count,
              Set(kinds) == Set(AutomaticRule.defaults.map(\.kind)) else {
            throw TidyError.message("자동정리 설정을 읽을 수 없어요. 분류별 설정을 다시 확인해 주세요.")
        }
        guard Set(customRules.map(\.id)).count == customRules.count else {
            throw TidyError.message("중복된 커스텀 규칙입니다. 설정을 확인해 주세요.")
        }
        for (index, rule) in customRules.enumerated() where rule.enabled {
            do {
                try rule.validate()
                _ = try Organizer.destinationFolder(named: rule.folderName, root: root)
            } catch { throw TidyError.message("커스텀 규칙 \(index + 1): \(error.localizedDescription)") }
        }
        for rule in rules where rule.enabled {
            do { _ = try Organizer.destinationFolder(named: rule.folderName, root: root) }
            catch { throw TidyError.message("\(rule.kind.rawValue): \(error.localizedDescription)") }
        }
    }
    /// First enabled custom match wins, then the enabled category fallback.
    public static func folderName(for entry: FileEntry, rules: [AutomaticRule], customRules: [CustomAutomaticRule] = []) -> String? {
        guard entry.canMove else { return nil }
        if let custom = customRules.first(where: { $0.matches(entry) }) { return custom.folderName }
        return rules.first { $0.kind == entry.kind && $0.enabled }?.folderName
    }
    public static func plans(for entries: [FileEntry], root: URL, rules: [AutomaticRule], customRules: [CustomAutomaticRule] = []) throws -> [MovePlan] {
        try validate(rules, root: root, customRules: customRules)
        var destinations: [String: URL] = [:]
        for entry in entries {
            if let name = folderName(for: entry, rules: rules, customRules: customRules) {
                destinations[entry.id] = try Organizer.destinationFolder(named: name, root: root)
            }
        }
        return Organizer.makePlans(for: entries.filter { destinations[$0.id] != nil }, root: root) {
            destinations[$0.id]!
        }
    }
}

/// Session baseline: turning monitoring on never sweeps existing files.
/// Pending files remain pending while downloading or while no rule matches.
public struct DownloadMonitor: Sendable {
    private var known: [String: Fingerprint] = [:]
    private var pending = Set<String>()
    private var initialized = false
    private var ignored = Set<String>()
    public init() {}
    public mutating func observe(_ entries: [FileEntry]) {
        let files = entries.filter { !$0.organized && $0.kind != .folder }
        let current = Dictionary(uniqueKeysWithValues: files.compactMap { entry in entry.fingerprint.map { (entry.id, $0) } })
        if initialized {
            for (id, fingerprint) in current {
                if let old = known[id] {
                    if old.device != fingerprint.device || old.inode != fingerprint.inode || old.birthSeconds != fingerprint.birthSeconds || old.birthNanos != fingerprint.birthNanos { pending.insert(id) }
                } else { pending.insert(id) }
            }
        }
        known = current
        pending.formIntersection(Set(current.keys))
        pending.subtract(ignored)
        ignored.subtract(current.keys)
        initialized = true
    }
    public func candidates(in entries: [FileEntry], rules: [AutomaticRule], customRules: [CustomAutomaticRule]) -> Set<String> {
        Set(entries.filter { pending.contains($0.id) && AutomaticOrganization.folderName(for: $0, rules: rules, customRules: customRules) != nil }.map(\.id))
    }
    public mutating func ignoreRestored(_ ids: Set<String>) { ignored.formUnion(ids); pending.subtract(ids) }
    public mutating func consume(_ ids: Set<String>) { pending.subtract(ids) }
}
