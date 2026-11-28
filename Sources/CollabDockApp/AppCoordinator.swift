import AppKit
import Foundation
import Observation
import CollabDockCore

public struct LocalRepoCandidate: Identifiable, Hashable, Sendable {
    public let path: String
    public let displayName: String
    public let repositoryFullName: String?
    public let lodyLocalProjectID: String?
    public let sourceLabel: String

    public var id: String { path }

    public init(
        path: String,
        displayName: String,
        repositoryFullName: String?,
        lodyLocalProjectID: String?,
        sourceLabel: String
    ) {
        self.path = path
        self.displayName = displayName
        self.repositoryFullName = repositoryFullName
        self.lodyLocalProjectID = lodyLocalProjectID
        self.sourceLabel = sourceLabel
    }
}

@MainActor
@Observable
public final class AppCoordinator {
    public var settings: AppSettings {
        didSet {
            guard !isPreviewMode else { return }
            persistSettings()
            if oldValue.launchAtLogin != settings.launchAtLogin {
                lastSystemNotice = systemIntegration.setLaunchAtLogin(settings.launchAtLogin)
            }
            if oldValue.appLanguage != settings.appLanguage {
                systemIntegration.applyInterfaceLanguage(settings.appLanguage.appleLanguagesOverride)
                needsRestartForLanguageChange = true
            }
            if oldValue.workspaceSearchRoots != settings.workspaceSearchRoots {
                refreshDiscoveredLocalRepos()
            }
            if oldValue.developerModeEnabled && !settings.developerModeEnabled {
                clearDemoItems()
                clearDemoUsageRuns()
            }
        }
    }
    public var items: [CollaborationItem] {
        didSet {
            guard !isPreviewMode else { return }
            syncRunningBlinkLoop()
        }
    }
    public var isMenuBarBlinking: Bool = false
    public var environment: EnvironmentSnapshot?
    public var isDetectingEnvironment: Bool = false
    public var isSyncing: Bool = false
    public var isPaused: Bool = false
    public var lastSyncAt: Date?
    public var lastSyncDiagnostic: String?
    public var lastSyncError: String?
    public var lastSystemNotice: String?
    public var needsRestartForLanguageChange: Bool = false
    public var latestRateLimit: RateLimitSnapshot?
    public var lastSyncWas304: Bool = false
    public var rateLimitedUntil: Date?
    public var effectivePollIntervalSeconds: Int = 60
    public var selectedTab: PopoverTab = .inbox
    public var selectedPlatformFilter: PlatformKind? = nil
    public var requestedDetailItemID: String? = nil
    public var requestedSettingsTab: SettingsView.SettingsTab? = nil
    public var availableModelsByEngine: [AgentEngine: [ModelOption]]
    public var lodyCatalog: LodyCatalogSnapshot?
    public var isRefreshingLodyCatalog: Bool = false
    public var discoveredLocalRepos: [LocalRepoCandidate] = []
    public var usageRuns: [ReviewUsageRun] = []
    public var isSyncingLodyUsage: Bool = false
    /// 内存中缓存已加载的 GitHub 头像，避免菜单栏弹窗反复开关时重新拉图闪烁
    public var githubAvatarImage: NSImage? = nil
    private var loadedAvatarURLString: String? = nil

    private let isPreviewMode: Bool
    private let autoStart: Bool
    private let settingsStore: any SettingsStoring
    private let detector: any EnvironmentDetecting
    private let connectorFactory: any ConnectorFactory
    private let backendFactory: any ExecutionBackendFactory
    private let systemIntegration: any SystemIntegrating
    private let clock: any ClockProviding
    private let ruleEngine = TriggerRuleEngine()
    private var taskStore: (any TaskStore)?
    private var lifecycleTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var blinkTask: Task<Void, Never>?
    private var lodyMonitorTasks: [String: Task<Void, Never>] = [:]
    private var runRegistry = ExecutionRunRegistry()
    private var syncState = InboxSyncState()
    private var isReconcilingPRStates: Bool = false
    /// 连续自动开始失败时的最近一次错误文案（相同错误连续出现只通知一次，中间成功过则重置）
    private var lastAutoStartFailureMessage: String? = nil

    public enum PopoverTab: String, CaseIterable, Identifiable {
        case inbox = "inbox"
        case completed = "completed"

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .inbox: return L("Inbox")
            case .completed: return L("Done")
            }
        }
    }

    public func relaunchApp() {
        systemIntegration.relaunchApplication()
    }

    public init(
        previewMode: Bool = false,
        autoStart: Bool = true,
        settingsStore: any SettingsStoring = SettingsStore(),
        detector: any EnvironmentDetecting = EnvironmentDetector(),
        taskStore: (any TaskStore)? = nil,
        makeDefaultTaskStore: () throws -> any TaskStore = { try SQLiteTaskStore() },
        connectorFactory: (any ConnectorFactory)? = nil,
        backendFactory: any ExecutionBackendFactory = DefaultExecutionBackendFactory(),
        systemIntegration: (any SystemIntegrating)? = nil,
        clock: any ClockProviding = SystemClock()
    ) {
        self.isPreviewMode = previewMode
        self.autoStart = autoStart
        self.settingsStore = settingsStore
        self.detector = detector
        self.connectorFactory = connectorFactory ?? DefaultConnectorFactory(detector: detector)
        self.backendFactory = backendFactory
        self.systemIntegration = systemIntegration ?? SystemIntegrationService.shared
        self.clock = clock
        self.availableModelsByEngine = Dictionary(
            uniqueKeysWithValues: AgentEngine.allCases.map { ($0, $0.defaultModels) }
        )

        if previewMode {
            self.settings = AppSettings()
            self.lodyCatalog = Self.makePreviewLodyCatalog()
            self.items = Self.makePreviewItems()
            self.usageRuns = Self.makePreviewUsageRuns()
            self.lastSyncAt = clock.now
            refreshDiscoveredLocalRepos()
        } else {
            let loadedSettings = settingsStore.load()
            self.settings = loadedSettings
            self.lodyCatalog = settingsStore.loadLodyCatalogCache()
            let initialInterval = max(60, loadedSettings.pollIntervalSeconds)
            self.effectivePollIntervalSeconds = initialInterval
            self.items = []
            self.syncState.effectivePollIntervalSeconds = initialInterval
            if let injectedStore = taskStore {
                self.taskStore = injectedStore
            } else {
                do {
                    self.taskStore = try makeDefaultTaskStore()
                } catch {
                    self.taskStore = nil
                    self.lastSystemNotice = L("Failed to open local database (data will not persist for this run): %@", error.localizedDescription)
                }
            }
            if autoStart {
                refreshDiscoveredLocalRepos()
            }
            self.systemIntegration.configureNotificationsIfAvailable()
            self.systemIntegration.onNotificationSelectedItem = { [weak self] itemID in
                self?.selectedTab = .inbox
                self?.requestedDetailItemID = itemID
            }
            self.systemIntegration.onNotificationAction = { [weak self] itemID, action in
                guard let self else { return }
                switch action {
                case .stop:
                    self.cancelRunningItem(id: itemID)
                case .openLody:
                    if let item = self.items.first(where: { $0.id == itemID }) {
                        self.openHandoff(for: item)
                    }
                }
            }
            if autoStart {
                startLifecycle()
            }
        }
    }

    public func startLifecycle() {
        lifecycleTask?.cancel()
        lifecycleTask = Task {
            await loadPersistedItems()
            await refreshEnvironment()
            resumeActiveLodyMonitors()
            await syncNow()
            startPollingLoop()
        }
    }

    public func stopLifecycle() {
        lifecycleTask?.cancel()
        lifecycleTask = nil
        pollingTask?.cancel()
        pollingTask = nil
        blinkTask?.cancel()
        blinkTask = nil
        isMenuBarBlinking = false
        for task in lodyMonitorTasks.values {
            task.cancel()
        }
        lodyMonitorTasks.removeAll()
    }

    public func loadPersistedItems() async {
        guard let store = taskStore else { return }
        do {
            let persisted = try await store.loadAllItems()
            // 若上次退出时有任务停留在 running/preparing，恢复为可重新确认状态
            self.items = persisted.map { item in
                var copy = item
                if copy.status == .preparing || copy.status == .running || copy.status == .publishing {
                    copy.status = .pendingConfirmation
                    copy.progressMessage = nil
                }
                return copy
            }
        } catch {
            reportPersistenceFailure(error, operation: .loadAllItems)
        }
        do {
            self.usageRuns = try await store.loadAllUsageRuns()
        } catch {
            reportPersistenceFailure(error, operation: .loadAllUsageRuns)
        }
    }

    private func reportPersistenceFailure(_ error: any Error, operation: PersistenceOperation) {
        if let persistenceError = error as? PersistenceError {
            lastSystemNotice = persistenceError.localizedDescription
        } else {
            lastSystemNotice = PersistenceError(operation: operation, underlying: error).localizedDescription
        }
    }

    private func persistItem(_ item: CollaborationItem) async {
        guard let store = taskStore else { return }
        do {
            try await store.upsertItem(item)
        } catch {
            reportPersistenceFailure(error, operation: .upsertItem)
        }
    }

    private func deletePersistedItem(id: String) async {
        guard let store = taskStore else { return }
        do {
            try await store.deleteItem(id: id)
        } catch {
            reportPersistenceFailure(error, operation: .deleteItem)
        }
    }

    private func persistUsageRun(_ run: ReviewUsageRun) async {
        guard let store = taskStore else { return }
        do {
            try await store.upsertUsageRun(run)
        } catch {
            reportPersistenceFailure(error, operation: .upsertUsageRun)
        }
    }

    // MARK: - 用量统计采集与 Lody 异步回补（关联 ITER-014）

    func usageReport(for range: UsageTimeRange) -> UsageSummaryReport {
        UsageAggregator.aggregate(runs: usageRuns, range: range)
    }

    func recordUsageRun(
        item: CollaborationItem,
        plan: ExecutionPlan,
        engine: AgentEngine,
        model: String,
        effort: ReasoningEffort,
        sessionID: String?,
        usage: AgentUsageMetrics?,
        durationSeconds: Double,
        isCouncilSecondary: Bool = false,
        succeeded: Bool = true
    ) {
        let lodyAgentName: String? = (engine == .lody)
            ? lodyAgentConfigDisplayName(for: plan.lodyAgentConfig ?? settings.lodyConfig.defaultAgentConfig)
            : nil
        let effectiveUsage = usage ?? AgentUsageMetrics(
            durationSeconds: durationSeconds,
            metricKind: engine == .lody ? .pendingSync : .exact
        )
        let run = ReviewUsageRun(
            itemID: item.id,
            platform: item.platform,
            scope: item.scope,
            externalRef: item.externalRef,
            title: item.title,
            reviewRound: item.reviewRound,
            continuityMode: plan.continuityMode,
            engine: engine,
            lodyAgentName: lodyAgentName,
            model: model,
            effort: effort,
            sessionID: sessionID,
            isCouncilSecondary: isCouncilSecondary,
            usage: effectiveUsage,
            succeeded: succeeded,
            createdAt: clock.now,
            syncedAt: effectiveUsage.metricKind == .exact ? clock.now : nil
        )
        usageRuns.insert(run, at: 0)
        if !isPreviewMode && !item.id.hasPrefix("demo-") {
            Task { await self.persistUsageRun(run) }
        }
    }

    public func syncPendingLodyUsage() async {
        guard !isPreviewMode, !isSyncingLodyUsage else { return }
        guard let lodyProbe = environment?.engines[.lody], lodyProbe.isInstalled else { return }

        let candidates = usageRuns
            .filter { !$0.id.hasPrefix("demo-usage-") && $0.engine == .lody && $0.syncedAt == nil && ($0.sessionID?.isEmpty == false) }
            .sorted { $0.createdAt < $1.createdAt }
            .prefix(10)
        guard !candidates.isEmpty else { return }

        isSyncingLodyUsage = true
        defer { isSyncingLodyUsage = false }

        let ws = settings.lodyConfig.workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPATH = environment?.resolvedPATH

        for run in candidates {
            guard let sid = run.sessionID else { continue }
            if let snap = await detector.fetchLodySessionUsage(
                lodyProbe: lodyProbe,
                sessionID: sid,
                workspace: ws.isEmpty ? nil : ws,
                resolvedPATH: resolvedPATH
            ) {
                guard let idx = usageRuns.firstIndex(where: { $0.id == run.id }) else { continue }
                await applyLodySnapshot(snap, toRunAt: idx)
            }
        }
    }

    private func startPollingLoop() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                var sleepSecs = max(60, max(self.settings.pollIntervalSeconds, self.effectivePollIntervalSeconds))
                if let until = self.rateLimitedUntil {
                    let wait = Int(ceil(until.timeIntervalSince(self.clock.now)))
                    if wait > sleepSecs {
                        sleepSecs = wait
                    }
                }
                try? await Task.sleep(for: .seconds(sleepSecs))
                if Task.isCancelled { return }
                if !self.isPaused {
                    await self.syncNow(manual: false)
                }
            }
        }
    }

    // MARK: - Computed State

    public var activePlatformsInInbox: [PlatformKind] {
        var seen: Set<PlatformKind> = []
        var ordered: [PlatformKind] = []
        for item in inboxItems where !seen.contains(item.platform) {
            seen.insert(item.platform)
            ordered.append(item.platform)
        }
        return ordered
    }

    public var inboxItems: [CollaborationItem] {
        items.filter { $0.status.isInboxActive }
    }

    public var filteredInboxItems: [CollaborationItem] {
        guard let filter = selectedPlatformFilter else { return inboxItems }
        return inboxItems.filter { $0.platform == filter }
    }

    public var completedItems: [CollaborationItem] {
        items.filter { !$0.status.isInboxActive && $0.completionReason != .superseded }
    }

    public var pendingConfirmationCount: Int {
        items.filter { $0.status == .pendingConfirmation }.count
    }

    public var runningCount: Int {
        items.filter {
            $0.status == .preparing
            || $0.status == .running
            || $0.status == .publishing
            || ($0.status == .draftReady && $0.remoteSessionStatus == .running)
        }.count
    }

    public var draftReadyCount: Int {
        items.filter { $0.status == .draftReady && $0.remoteSessionStatus != .running }.count
    }

    private func syncRunningBlinkLoop() {
        guard autoStart else { return }
        let shouldBlink = runningCount > 0
        if shouldBlink {
            guard blinkTask == nil else { return }
            blinkTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(2500))
                    guard !Task.isCancelled, let self, self.runningCount > 0 else { break }
                    self.isMenuBarBlinking = true
                    try? await Task.sleep(for: .milliseconds(160))
                    guard !Task.isCancelled else { break }
                    self.isMenuBarBlinking = false
                }
                self?.isMenuBarBlinking = false
                self?.blinkTask = nil
            }
        } else {
            blinkTask?.cancel()
            blinkTask = nil
            if isMenuBarBlinking {
                isMenuBarBlinking = false
            }
        }
    }

    var hasDemoItems: Bool {
        items.contains { $0.id.hasPrefix("demo-") }
    }

    var hasDemoUsageRuns: Bool {
        usageRuns.contains { $0.id.hasPrefix("demo-usage-") }
    }

    var resolvedGitHubUsername: String {
        if let configured = settings.connectors.first(where: { $0.platform == .github })?.accountHandle,
           !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return configured.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return environment?.githubAuth.username ?? ""
    }

    /// GitHub 展示别名（如 `Alex`）；若与 login 相同或未设置则返回 nil
    var resolvedGitHubDisplayName: String? {
        guard let name = environment?.githubAuth.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return nil
        }
        if name.lowercased() == resolvedGitHubUsername.lowercased() {
            return nil
        }
        return name
    }

    var resolvedGitHubAvatarURL: URL? {
        if let raw = environment?.githubAuth.avatarURL, !raw.isEmpty, let url = URL(string: raw) {
            return url
        }
        let user = resolvedGitHubUsername
        if !user.isEmpty {
            return URL(string: "https://github.com/\(user).png?size=80")
        }
        return nil
    }

    func loadGitHubAvatarIfNeeded() {
        guard !isPreviewMode, let url = resolvedGitHubAvatarURL else { return }
        let key = url.absoluteString
        guard loadedAvatarURLString != key || githubAvatarImage == nil else { return }
        loadedAvatarURLString = key
        Task { [weak self] in
            var req = URLRequest(url: url)
            req.timeoutInterval = 8
            if let (data, resp) = try? await URLSession.shared.data(for: req),
               let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
               let img = NSImage(data: data) {
                self?.githubAvatarImage = img
            }
        }
    }

    func isEngineInstalled(_ engine: AgentEngine) -> Bool {
        guard let environment else { return true }
        return environment.isEngineReady(engine)
    }

    // MARK: - Environment & Live GitHub Sync

    public func refreshEnvironment() async {
        guard !isDetectingEnvironment else { return }
        isDetectingEnvironment = true
        defer { isDetectingEnvironment = false }

        let snapshot = await detector.detectAll(customPaths: settings.customExecutablePaths)
        self.environment = snapshot

        if let detectedUser = snapshot.githubAuth.username,
           let idx = settings.connectors.firstIndex(where: { $0.platform == .github }),
           settings.connectors[idx].accountHandle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            settings.connectors[idx].accountHandle = detectedUser
        }
        loadGitHubAvatarIfNeeded()

        // Lody 目录探测独立异步执行，不阻塞首屏 GitHub / 本地 CLI 状态就绪
        if snapshot.engines[.lody]?.isInstalled == true {
            Task { [weak self] in
                await self?.refreshLodyCatalog()
            }
        }
    }

    public func refreshLodyCatalog() async {
        guard !isPreviewMode, !isRefreshingLodyCatalog else { return }
        guard let lodyProbe = environment?.engines[.lody], lodyProbe.isInstalled else { return }
        isRefreshingLodyCatalog = true
        defer { isRefreshingLodyCatalog = false }

        let ws = settings.lodyConfig.workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        if let catalog = await detector.fetchLodyCatalog(
            lodyProbe: lodyProbe,
            workspace: ws.isEmpty ? nil : ws,
            resolvedPATH: environment?.resolvedPATH
        ) {
            self.lodyCatalog = catalog
            settingsStore.saveLodyCatalogCache(catalog)
            refreshDiscoveredLocalRepos()

            // 将旧版别名（如 "antigravity" / "claude" / "codex"）平滑绑定到真实发现的 Lody Agent Config ID
            let currentSelector = settings.lodyConfig.defaultAgentConfig
            if currentSelector != "default",
               let matched = catalog.matchAgentConfig(selector: currentSelector),
               matched.id != currentSelector {
                if let savedModel = settings.lodyConfig.defaultModelByAgentConfig[currentSelector],
                   settings.lodyConfig.defaultModelByAgentConfig[matched.id] == nil {
                    settings.lodyConfig.defaultModelByAgentConfig[matched.id] = savedModel
                }
                settings.lodyConfig.defaultAgentConfig = matched.id
            }
        }
    }

    // MARK: - 仓库 -> 本地目录映射与发现（ITER-012）

    func refreshDiscoveredLocalRepos() {
        var result: [LocalRepoCandidate] = []
        var seenPaths: Set<String> = []

        if let projects = lodyCatalog?.localProjects {
            for proj in projects {
                let normalized = URL(fileURLWithPath: (proj.rootPath as NSString).expandingTildeInPath).standardizedFileURL.path
                guard !seenPaths.contains(normalized) else { continue }
                seenPaths.insert(normalized)
                result.append(
                    LocalRepoCandidate(
                        path: normalized,
                        displayName: proj.name,
                        repositoryFullName: proj.repositoryFullName?.lowercased(),
                        lodyLocalProjectID: proj.id,
                        sourceLabel: L("From Lody")
                    )
                )
            }
        }

        if !isPreviewMode {
            let scanned = RepoScanner().scanRepositories(in: settings.workspaceSearchRoots)
            for (repoName, url) in scanned.sorted(by: { $0.key < $1.key }) {
                let normalized = url.standardizedFileURL.path
                guard !seenPaths.contains(normalized) else { continue }
                seenPaths.insert(normalized)
                result.append(
                    LocalRepoCandidate(
                        path: normalized,
                        displayName: url.lastPathComponent,
                        repositoryFullName: repoName.lowercased(),
                        lodyLocalProjectID: nil,
                        sourceLabel: L("Workspace scan")
                    )
                )
            }
        }

        self.discoveredLocalRepos = result
    }

    struct RepositoryMappingRow: Identifiable, Hashable {
        let repository: String
        let resolvedPath: String?
        let isOverridden: Bool
        let candidates: [LocalRepoCandidate]

        var id: String { repository }
    }

    var knownRepositoryMappings: [RepositoryMappingRow] {
        var allRepos: Set<String> = Set(settings.repositoryDirectoryOverrides.keys.map { $0.lowercased() })
        for item in discoveredLocalRepos {
            if let repo = item.repositoryFullName, !repo.isEmpty {
                allRepos.insert(repo.lowercased())
            }
        }
        return allRepos.sorted().map { repo in
            let matches = localRepoCandidates(forRepository: repo)
            let overridePath = settings.repositoryDirectoryOverrides[repo]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let isOverridden = (overridePath?.isEmpty == false)
            let resolved = isOverridden ? overridePath : matches.first?.path
            return RepositoryMappingRow(
                repository: repo,
                resolvedPath: resolved,
                isOverridden: isOverridden,
                candidates: matches
            )
        }
    }

    func localRepoCandidates(forRepository repo: String?) -> [LocalRepoCandidate] {
        guard let raw = repo?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return discoveredLocalRepos
        }
        let target = raw.lowercased()
        let shortName = target.split(separator: "/").last.map(String.init) ?? target
        let exact = discoveredLocalRepos.filter { $0.repositoryFullName?.lowercased() == target }
        if !exact.isEmpty {
            return exact
        }
        return discoveredLocalRepos.filter { $0.displayName.lowercased() == shortName }
    }

    func resolvedDirectoryInfo(
        forRepository repo: String?,
        override: String? = nil
    ) -> (path: String?, displayName: String, lodyProjectID: String?) {
        let explicit = override?.trimmingCharacters(in: .whitespacesAndNewlines)
        let repoKey = repo?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pinned = repoKey.flatMap { settings.repositoryDirectoryOverrides[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }

        let chosenPath: String?
        if let explicit, !explicit.isEmpty {
            chosenPath = explicit
        } else if let pinned, !pinned.isEmpty {
            chosenPath = pinned
        } else {
            chosenPath = localRepoCandidates(forRepository: repo).first?.path
        }

        guard let chosenPath else {
            return (nil, L("Auto shallow clone"), nil)
        }
        let normalized = URL(fileURLWithPath: (chosenPath as NSString).expandingTildeInPath).standardizedFileURL.path
        if let matched = discoveredLocalRepos.first(where: { $0.path == normalized }) {
            return (normalized, matched.displayName, matched.lodyLocalProjectID)
        }
        let folderName = URL(fileURLWithPath: normalized).lastPathComponent
        return (normalized, folderName.isEmpty ? normalized : folderName, nil)
    }

    func setRepositoryDirectoryOverride(repository: String, path: String?) {
        let key = repository.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return }
        if let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let normalized = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
            settings.repositoryDirectoryOverrides[key] = normalized
        } else {
            settings.repositoryDirectoryOverrides.removeValue(forKey: key)
        }
    }

    // MARK: - Lody.ai Agent Config & Model Resolution (ITER-009)

    var lodyAgentConfigOptions: [LodyAgentConfigOption] {
        if let discovered = lodyCatalog?.agentConfigs, !discovered.isEmpty {
            return discovered
        }
        return LodyAgentConfigOption.fallbackPresets
    }

    func lodyAgentConfigDisplayName(for selector: String) -> String {
        let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "default" {
            return L("Workspace Default Agent")
        }
        if let matched = lodyCatalog?.matchAgentConfig(selector: trimmed) {
            return matched.name
        }
        if let preset = LodyAgentConfigOption.fallbackPresets.first(where: {
            $0.id.lowercased() == trimmed.lowercased() || $0.name.lowercased() == trimmed.lowercased()
        }) {
            return preset.name
        }
        return trimmed
    }

    func modelsForLody(agentConfig selector: String) -> [ModelOption] {
        LodyCatalogSnapshot.resolveModels(
            forAgentConfig: selector,
            catalog: lodyCatalog,
            fallbackByEngine: availableModelsByEngine
        )
    }

    func preferredLodyModel(forAgentConfig selector: String) -> String {
        let options = modelsForLody(agentConfig: selector)
        let normalizedKey = lodyCatalog?.matchAgentConfig(selector: selector)?.id ?? selector
        if let saved = settings.lodyConfig.defaultModelByAgentConfig[normalizedKey]
            ?? settings.lodyConfig.defaultModelByAgentConfig[selector],
           options.contains(where: { $0.id == saved }) {
            return saved
        }
        return options.first?.id ?? "default"
    }

    func setPreferredLodyModel(_ modelID: String, forAgentConfig selector: String) {
        let normalizedKey = lodyCatalog?.matchAgentConfig(selector: selector)?.id ?? selector
        settings.lodyConfig.defaultModelByAgentConfig[normalizedKey] = modelID
    }

    func modesForLody(agentConfig selector: String) -> [AgentModeOption] {
        LodyCatalogSnapshot.resolveModes(forAgentConfig: selector, catalog: lodyCatalog)
    }

    func preferredLodyMode(forAgentConfig selector: String) -> String {
        let options = modesForLody(agentConfig: selector)
        let matched = lodyCatalog?.matchAgentConfig(selector: selector)
        let normalizedKey = matched?.id ?? selector
        if let saved = settings.lodyConfig.defaultModeByAgentConfig[normalizedKey]
            ?? settings.lodyConfig.defaultModeByAgentConfig[selector],
           options.contains(where: { $0.id == saved }) {
            return saved
        }
        if let ro = matched?.readOnlyModeID, options.contains(where: { $0.id == ro }) {
            return ro
        }
        if options.contains(where: { $0.id == "plan" }) {
            return "plan"
        }
        if options.contains(where: { $0.id == "read-only" }) {
            return "read-only"
        }
        return options.first?.id ?? "__agent_default__"
    }

    func setPreferredLodyMode(_ modeID: String, forAgentConfig selector: String) {
        let normalizedKey = lodyCatalog?.matchAgentConfig(selector: selector)?.id ?? selector
        settings.lodyConfig.defaultModeByAgentConfig[normalizedKey] = modeID
    }

    var resolvedLodyWorkspaceForDeepLink: String {
        let configured = settings.lodyConfig.workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty {
            return configured
        }
        return lodyCatalog?.workspaceID ?? ""
    }

    /// 菜单栏弹窗打开时触发：距上次 Search 对齐超过 60 秒则自动执行一次带对齐的同步（仍遵守限流退避），并保留 PR 状态对齐
    public func popoverDidOpen() async {
        guard !isPreviewMode else { return }
        let now = clock.now
        let needsSearchSync = syncState.lastReconcileAt == nil
            || now.timeIntervalSince(syncState.lastReconcileAt!) >= 60
        if needsSearchSync {
            await performSync(manual: false, reconcileIntervalSeconds: 60)
        } else {
            await reconcileInboxGitHubPRStates(force: false)
        }
    }

    public func syncNow(manual: Bool = false) async {
        await performSync(manual: manual, reconcileIntervalSeconds: 180)
    }

    private func performSync(manual: Bool, reconcileIntervalSeconds: TimeInterval) async {
        guard !isPreviewMode, !isSyncing else { return }
        guard settings.connectors.contains(where: { $0.platform == .github && $0.isEnabled }) else {
            return
        }
        guard let store = taskStore else {
            lastSyncError = L("Local database unavailable; cannot sync inbox")
            return
        }

        // 若手动刷新且之前缺 notifications 权限，先重探一次 gh auth status，用户刷完权限无需重启 App 即可秒切 304 零消耗模式
        if manual && environment?.githubAuth.hasNotificationsScope == false {
            await refreshEnvironment()
        }

        isSyncing = true
        lastSyncError = nil
        defer {
            isSyncing = false
            lastSyncAt = clock.now
        }

        let rules = settings.effectiveRules(for: .github)
        let connectorContext = ConnectorBuildContext(
            platform: .github,
            rules: rules,
            environment: environment
        )
        guard let source = connectorFactory.makeSource(context: connectorContext) else {
            return
        }

        let syncService = InboxSyncService(
            source: source,
            prStatusQuery: connectorFactory.makePRStatusQuery(context: connectorContext),
            prFetcher: connectorFactory.makePRFetcher(context: connectorContext),
            store: store,
            ruleEngine: ruleEngine,
            clock: clock
        )

        do {
            let result = try await syncService.sync(
                InboxSyncRequest(
                    manual: manual,
                    existingItems: items,
                    rules: rules,
                    currentHandle: resolvedGitHubUsername,
                    autoCompleteApprovedOrClosedPRs: false,
                    previousState: syncState,
                    reconcileIntervalSeconds: reconcileIntervalSeconds
                )
            )
            syncState = result.state
            rateLimitedUntil = result.state.rateLimitedUntil
            effectivePollIntervalSeconds = result.state.effectivePollIntervalSeconds

            if result.backoff.wasSkippedDueToBackoff {
                return
            }
            if result.backoff.isRateLimited {
                lastSyncError = result.backoff.errorMessage
                return
            }

            lastSyncWas304 = result.wasNotModified
            if let rl = result.rateLimit {
                latestRateLimit = rl
            }
            lastSyncDiagnostic = result.diagnosticMessage

            for superseded in result.supersededItems {
                if let idx = items.firstIndex(where: { $0.id == superseded.id }) {
                    items[idx] = superseded
                }
            }
            var newlyInsertedItems: [CollaborationItem] = []
            for newItem in result.newItems.reversed() {
                if !items.contains(where: { $0.id == newItem.id }) {
                    items.insert(newItem, at: 0)
                    newlyInsertedItems.append(newItem)
                }
            }

            var autoStartedIDs: Set<String> = []
            for candidate in newlyInsertedItems.reversed() {
                guard AutoStartPolicy.shouldAutoStart(candidate, settings: settings.autoStart) else {
                    continue
                }
                autoStartedIDs.insert(candidate.id)
                let plan = defaultPlan(for: candidate)
                confirmAndRun(itemID: candidate.id, plan: plan, autoStarted: true)
            }

            for notification in result.notifications {
                switch notification {
                case .incomingTask(let item):
                    if autoStartedIDs.contains(item.id) {
                        continue
                    }
                    systemIntegration.postIncomingTaskNotification(
                        for: item,
                        enabled: settings.notificationsEnabled
                    )
                }
            }
            await reconcileInboxGitHubPRStates(force: manual)
        } catch let persistenceError as PersistenceError {
            reportPersistenceFailure(persistenceError, operation: persistenceError.operation)
            lastSyncError = persistenceError.localizedDescription
        } catch {
            lastSyncError = error.localizedDescription
        }
    }

    /// GraphQL 单次批量对齐收件箱中活跃 GitHub PR 的远端状态（Approve / Merged / Closed 自动归档；Request Changes 保留跟进，关联 ITER-017）
    public func reconcileInboxGitHubPRStates(force: Bool = false) async {
        guard !isPreviewMode,
              !isReconcilingPRStates,
              settings.autoCompleteApprovedOrClosedPRs,
              settings.connectors.contains(where: { $0.platform == .github && $0.isEnabled }) else {
            return
        }

        if !force, let last = syncState.lastPRStateReconcileAt, clock.now.timeIntervalSince(last) < 25 {
            return
        }

        // 收件箱中跳过正在执行本地进程或 Lody 仍在审查中的条目，且收件箱空时 0 API 消耗
        let targets = PRStateReconciler.targets(in: items)
        guard !targets.isEmpty else { return }

        let connectorContext = ConnectorBuildContext(
            platform: .github,
            rules: settings.effectiveRules(for: .github),
            environment: environment
        )
        guard let statusQuery = connectorFactory.makePRStatusQuery(context: connectorContext) else {
            return
        }

        isReconcilingPRStates = true
        defer {
            isReconcilingPRStates = false
            syncState.lastPRStateReconcileAt = clock.now
        }

        let result: PRStatusBatchResult
        do {
            result = try await statusQuery.fetchPRStatusSnapshots(targets: targets)
        } catch {
            lastSyncError = error.localizedDescription
            return
        }
        let viewer = result.viewerLogin ?? resolvedGitHubUsername
        guard !result.snapshots.isEmpty else { return }

        // await 之后基于当前最新 items 计算更新，按 itemID 同步回写（循环内不 await，避免下标错位）
        let updates = PRStateReconciler.updates(
            for: items,
            snapshots: result.snapshots,
            viewerLogin: viewer
        )
        var itemsToPersist: [CollaborationItem] = []
        itemsToPersist.reserveCapacity(updates.count)
        for update in updates {
            guard let idx = items.firstIndex(where: { $0.id == update.itemID }) else { continue }
            if update.completionReason != nil {
                lodyMonitorTasks[update.itemID]?.cancel()
                lodyMonitorTasks.removeValue(forKey: update.itemID)
            }
            PRStateReconciler.apply(update, to: &items[idx])
            itemsToPersist.append(items[idx])
        }

        for updated in itemsToPersist {
            await persistItem(updated)
        }
    }

    // MARK: - Execution Plan & Real End-to-End Execution (M3 / TASK-015)

    /// 检索同平台、同仓库、同 PR 编号的最近一次已完成/草稿就绪的审查记录，自动挂载复审记忆上下文
    public func findPreviousReview(for item: CollaborationItem) -> PreviousReviewContext? {
        InboxSyncService.findPreviousReview(
            for: item,
            in: items,
            defaultEngine: settings.defaultEngine
        )
    }

    func presets(for item: CollaborationItem) -> [TaskPreset] {
        switch item.payload {
        case .codeChange:
            let preferred = settings.presets.filter { $0.category == .codeReview }
            return preferred.isEmpty ? settings.presets : preferred
        case .issueTicket, .conversation:
            let preferred = settings.presets.filter { $0.category != .codeReview }
            return preferred.isEmpty ? settings.presets : preferred
        }
    }

    public func defaultPlan(for item: CollaborationItem) -> ExecutionPlan {
        let prev = item.previousReview
        let continuityMode: ReviewContinuityMode
        if let prev {
            continuityMode = (prev.engine == .lody && prev.canContinueSameSession)
                ? .continueSessionIncremental
                : .freshSessionIncremental
        } else {
            continuityMode = .freshSessionFull
        }

        let lodyAgent = settings.lodyConfig.defaultAgentConfig
        let model: String
        if let suggested = item.suggestedModel, !suggested.isEmpty {
            model = suggested
        } else {
            model = preferredLodyModel(forAgentConfig: lodyAgent)
        }

        let candidates = presets(for: item)
        let presetID: String
        if let hint = item.suggestedPresetID,
           let matched = settings.presets.first(where: { $0.id == hint || $0.id.contains(hint) }) {
            presetID = matched.id
        } else {
            presetID = candidates.first?.id ?? settings.presets.first?.id ?? "code-review-general"
        }

        return ExecutionPlan(
            engine: .lody,
            model: model,
            lodyAgentConfig: lodyAgent,
            effort: settings.defaultEffort,
            mode: preferredLodyMode(forAgentConfig: lodyAgent),
            presetID: presetID,
            launchMode: .nativeBackgroundSession,
            sandboxPolicy: .readOnly,
            targetDirectoryOverride: nil,
            useIsolatedWorktree: settings.lodyConfig.useLodyWorktree,
            continuityMode: continuityMode,
            previousReview: prev,
            extraInstructions: ""
        )
    }

    public func togglePause() {
        isPaused.toggle()
    }

    public func refreshNow() {
        if isPreviewMode {
            lastSyncAt = clock.now
            return
        }
        Task {
            await syncNow(manual: true)
        }
    }

    public func dismissItem(id: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].status = .dismissed
        items[idx].progressMessage = nil
        let updated = items[idx]
        if !isPreviewMode && !updated.id.hasPrefix("demo-") {
            Task { await self.persistItem(updated) }
        }
    }

    /// 邮件式归档：标为已完成（移入「已完成」分栏，保留记录与会话入口）
    public func markItemCompleted(id: String) {
        lodyMonitorTasks[id]?.cancel()
        lodyMonitorTasks.removeValue(forKey: id)
        runRegistry.cancel(itemID: id)
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].status = .completed
        items[idx].completionReason = .manual
        items[idx].progressMessage = nil
        items[idx].errorMessage = nil
        if items[idx].remoteSessionStatus == .running {
            items[idx].remoteSessionStatus = .completed
        }
        let updated = items[idx]
        if !isPreviewMode && !updated.id.hasPrefix("demo-") {
            Task { await self.persistItem(updated) }
        }
    }

    /// 彻底删除单条列表记录（同步移除 SQLite collaboration_items，但保留 seen_events 去重记录与 review_usage_runs 用量账本）
    public func deleteItem(id: String) {
        lodyMonitorTasks[id]?.cancel()
        lodyMonitorTasks.removeValue(forKey: id)
        runRegistry.cancel(itemID: id)
        items.removeAll { $0.id == id }
        if !isPreviewMode && !id.hasPrefix("demo-") {
            Task { await self.deletePersistedItem(id: id) }
        }
    }

    /// 一键清空「已完成」列表（不删除任何用量统计记录）
    public func clearCompletedItems() {
        let toDelete = items.filter { !$0.status.isInboxActive }
        guard !toDelete.isEmpty else { return }
        items.removeAll { !$0.status.isInboxActive }
        if !isPreviewMode {
            let persistentIDs = toDelete.map(\.id).filter { !$0.hasPrefix("demo-") }
            Task {
                for id in persistentIDs {
                    await self.deletePersistedItem(id: id)
                }
            }
        }
    }

    public func retryFailedItem(id: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].status = .pendingConfirmation
        items[idx].errorMessage = nil
        items[idx].progressMessage = nil
        selectedTab = .inbox
        requestedDetailItemID = id
    }

    public func openHandoff(for item: CollaborationItem) {
        guard let handle = item.sessionHandle, handle.engine == .lody else { return }
        systemIntegration.openSessionHandoff(
            handle: handle,
            lodyWorkspace: resolvedLodyWorkspaceForDeepLink
        )
    }

    public func importPullRequest(reference: String) async -> Result<CollaborationItem, Error> {
        guard !isPreviewMode else {
            return .failure(NSError(domain: "CollabDock", code: 1, userInfo: [NSLocalizedDescriptionKey: L("Cannot fetch PR over network in preview mode")]))
        }
        guard let store = taskStore else {
            let err = NSError(domain: "CollabDock", code: 2, userInfo: [NSLocalizedDescriptionKey: L("Local database unavailable; cannot import PR")])
            return .failure(err)
        }
        let connectorContext = ConnectorBuildContext(
            platform: .github,
            rules: settings.effectiveRules(for: .github),
            environment: environment
        )
        let source = connectorFactory.makeSource(context: connectorContext) ?? NullCollaborationSource(platform: .github)
        let fetcher = connectorFactory.makePRFetcher(context: connectorContext)
        let syncService = InboxSyncService(
            source: source,
            prFetcher: fetcher,
            store: store,
            ruleEngine: ruleEngine,
            clock: clock
        )
        do {
            let importResult = try await syncService.importPullRequestResult(reference: reference, existingItems: items)
            let item = importResult.item
            for superseded in importResult.supersededItems {
                if let idx = items.firstIndex(where: { $0.id == superseded.id }) {
                    items[idx] = superseded
                }
            }
            if let existingIdx = items.firstIndex(where: { $0.id == item.id }) {
                items[existingIdx] = item
            } else {
                items.insert(item, at: 0)
            }
            selectedTab = .inbox
            requestedDetailItemID = item.id
            return .success(item)
        } catch let persistenceError as PersistenceError {
            reportPersistenceFailure(persistenceError, operation: persistenceError.operation)
            return .failure(persistenceError)
        } catch {
            return .failure(error)
        }
    }

    func loadDemoItems() {
        let demos = Self.makePreviewItems()
        for demo in demos.reversed() {
            if !items.contains(where: { $0.id == demo.id }) {
                items.insert(demo, at: 0)
            }
        }
    }

    func clearDemoItems() {
        items.removeAll { $0.id.hasPrefix("demo-") }
    }

    /// 仅开发者模式可用：向内存注入示例统计数据预览图表与导出（绝不写入本地 SQLite 账本）
    func loadDemoUsageRuns() {
        let demos = Self.makePreviewUsageRuns()
        for demo in demos.reversed() {
            if !usageRuns.contains(where: { $0.id == demo.id }) {
                usageRuns.insert(demo, at: 0)
            }
        }
        usageRuns.sort { $0.createdAt > $1.createdAt }
    }

    func clearDemoUsageRuns() {
        usageRuns.removeAll { $0.id.hasPrefix("demo-usage-") }
    }

    func setDeveloperMode(_ enabled: Bool) {
        settings.developerModeEnabled = enabled
        if !enabled {
            clearDemoItems()
            clearDemoUsageRuns()
        }
    }

    func exportTeamPresetJSON(teamName: String) -> String? {
        guard let data = try? settingsStore.exportTeamPresetData(teamName: teamName, from: settings) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func importTeamPresetJSON(_ jsonString: String) -> Result<String, Error> {
        do {
            guard let data = jsonString.data(using: .utf8) else {
                return .failure(NSError(domain: "CollabDock", code: 1, userInfo: [NSLocalizedDescriptionKey: L("Invalid UTF-8 text")]))
            }
            let preset = try settingsStore.decodeTeamPreset(from: data)
            settings.applyTeamPreset(preset)
            return .success(L("Merged team \"%@\" settings (kept your personal model and path preferences)", preset.teamName))
        } catch {
            return .failure(error)
        }
    }

    /// 切换「自动开始审查」暂停/恢复状态（暂停期间进来的请求留在待确认，恢复后不补派）
    public func toggleAutoStartPause() {
        settings.autoStart.isPaused.toggle()
    }

    /// 设置页只读摘要：展示自动开始审查时采用的默认 Lody Agent 与模型
    public var autoStartDefaultSummary: String {
        let agentConfig = settings.lodyConfig.defaultAgentConfig
        let agentLabel = lodyAgentConfigDisplayName(for: agentConfig)
        let modelID = preferredLodyModel(forAgentConfig: agentConfig)
        let modelLabel: String
        if modelID.isEmpty || modelID == "default" {
            modelLabel = L("Default Model")
        } else {
            modelLabel = modelsForLody(agentConfig: agentConfig)
                .first(where: { $0.id == modelID })?
                .displayName ?? modelID
        }
        return "\(agentLabel) · \(modelLabel)"
    }

    /// Lody 审查执行管线：工作区路由 → 派发 Lody 后台会话 → 记账 → 加 👀 → 实时追踪状态与上下文用量
    @discardableResult
    public func confirmAndRun(itemID: String, plan: ExecutionPlan, autoStarted: Bool = false) -> Task<Void, Never>? {
        guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return nil }

        var effectivePlan = plan
        let wasDirectEnginePlan = effectivePlan.engine != .lody
        if wasDirectEnginePlan {
            effectivePlan.engine = .lody
            effectivePlan.model = "default"
        }
        effectivePlan.launchMode = .nativeBackgroundSession

        let activeLodyCfg = effectivePlan.lodyAgentConfig ?? settings.lodyConfig.defaultAgentConfig
        effectivePlan.lodyAgentConfig = activeLodyCfg

        if !autoStarted {
            settings.defaultEngine = .lody
            settings.lodyConfig.defaultAgentConfig = activeLodyCfg
            if !wasDirectEnginePlan {
                setPreferredLodyModel(effectivePlan.model, forAgentConfig: activeLodyCfg)
                if let chosenMode = effectivePlan.mode, !chosenMode.isEmpty {
                    setPreferredLodyMode(chosenMode, forAgentConfig: activeLodyCfg)
                }
            }
            settings.defaultEffort = effectivePlan.effort
        }

        items[idx].wasAutoStarted = autoStarted
        let targetItem = items[idx]
        items[idx].status = .preparing
        items[idx].errorMessage = nil
        items[idx].progressMessage = CoreL10n.string("Preparing isolated context...")

        let ticket = runRegistry.begin(itemID: itemID)

        // 演示条目仍走安全模拟，防止向虚构仓库 `acme/backend` 发起真实 git clone / Lody 派发
        if isPreviewMode || targetItem.id.hasPrefix("demo-") {
            return runDemoSimulation(ticket: ticket, targetItem: targetItem, plan: effectivePlan)
        }

        let preset = settings.presets.first(where: { $0.id == effectivePlan.presetID })
            ?? TaskPreset.defaults[0]
        let searchRoots = settings.workspaceSearchRoots
        let lodyConfig = settings.lodyConfig
        let lodyCatalogSnapshot = lodyCatalog
        let notifyEnabled = settings.notificationsEnabled
        let notifyAutoStart = settings.autoStart.notifyOnStart
        let addReaction = settings.markReviewStartWithReaction
        let connectorRules = settings.effectiveRules(for: targetItem.platform)
        let lodyAgentDisplayName = lodyAgentConfigDisplayName(for: activeLodyCfg)

        let repoNameForResolve = targetItem.payload.linkedRepository
        if let repoNameForResolve, let explicitDir = effectivePlan.targetDirectoryOverride, !explicitDir.isEmpty {
            setRepositoryDirectoryOverride(repository: repoNameForResolve, path: explicitDir)
        }
        let resolvedDirInfo = resolvedDirectoryInfo(
            forRepository: repoNameForResolve,
            override: effectivePlan.targetDirectoryOverride
        )

        guard let store = taskStore else {
            runRegistry.finish(ticket)
            if let updatedIdx = items.firstIndex(where: { $0.id == itemID }) {
                let errMsg = L("Local database unavailable; cannot run review")
                items[updatedIdx].status = .failed
                items[updatedIdx].progressMessage = nil
                items[updatedIdx].errorMessage = errMsg
                if autoStarted {
                    notifyAutoStartFailureIfNeeded(for: items[updatedIdx], message: errMsg, enabled: notifyEnabled)
                }
            }
            return nil
        }

        let runPlan = effectivePlan
        return Task {
            defer {
                self.runRegistry.finish(ticket)
            }

            do {
                // 冷启动竞态防护：若刚启动 App 就立即发起审查，先补齐本机 PATH 与 CLI 探测
                if self.environment == nil {
                    await self.refreshEnvironment()
                }
                guard self.runRegistry.isCurrent(ticket), !ticket.isCancelled else {
                    if self.runRegistry.isCurrent(ticket) {
                        restorePendingOnCancel(itemID: itemID)
                    }
                    return
                }
                let envSnapshot = self.environment

                let lodyBackend = self.backendFactory.makeLodyBackend(
                    config: lodyConfig,
                    catalog: lodyCatalogSnapshot
                )
                let connectorContext = ConnectorBuildContext(
                    platform: targetItem.platform,
                    rules: connectorRules,
                    environment: envSnapshot
                )
                let reactor = self.connectorFactory.makePRReactor(context: connectorContext)
                let executionService = ReviewExecutionService(
                    backend: lodyBackend,
                    store: store,
                    clock: self.clock,
                    reactor: reactor
                )
                let executionRequest = ReviewExecutionRequest(
                    item: targetItem,
                    plan: runPlan,
                    preset: preset,
                    ticket: ticket,
                    searchRoots: searchRoots,
                    preferredLocalPath: resolvedDirInfo.path,
                    environment: envSnapshot,
                    lodyAgentDisplayName: lodyAgentDisplayName,
                    addStartReaction: addReaction
                )

                let outcome = try await executionService.execute(executionRequest) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.updateProgress(for: ticket, status: progress.status, message: progress.message)
                    }
                }

                guard self.runRegistry.isCurrent(ticket) else {
                    return
                }

                switch outcome {
                case .cancelled:
                    restorePendingOnCancel(itemID: itemID)

                case .backgroundDispatched(let dispatched, let handle, _, let recordedRuns):
                    for run in recordedRuns.reversed() {
                        usageRuns.insert(run, at: 0)
                    }
                    if autoStarted {
                        self.lastAutoStartFailureMessage = nil
                        self.systemIntegration.postAutoStartNotification(
                            for: dispatched,
                            enabled: notifyEnabled && notifyAutoStart
                        )
                    }
                    if let updatedIdx = items.firstIndex(where: { $0.id == itemID }) {
                        items[updatedIdx] = dispatched
                    }
                    selectedTab = .inbox

                    if let sid = handle?.sessionID, !sid.isEmpty {
                        startMonitoringLodySession(itemID: itemID, sessionID: sid, notifyEnabled: notifyEnabled)
                    }
                }
            } catch {
                guard self.runRegistry.isCurrent(ticket) else {
                    return
                }
                if ticket.isCancelled {
                    restorePendingOnCancel(itemID: itemID)
                    return
                }
                if let persistenceError = error as? PersistenceError {
                    reportPersistenceFailure(persistenceError, operation: persistenceError.operation)
                }
                if let updatedIdx = items.firstIndex(where: { $0.id == itemID }) {
                    let errMsg = error.localizedDescription
                    items[updatedIdx].status = .failed
                    items[updatedIdx].progressMessage = nil
                    items[updatedIdx].errorMessage = errMsg
                    selectedTab = .inbox
                    if autoStarted {
                        notifyAutoStartFailureIfNeeded(for: items[updatedIdx], message: errMsg, enabled: notifyEnabled)
                    }
                }
            }
        }
    }

    private func notifyAutoStartFailureIfNeeded(for item: CollaborationItem, message: String, enabled: Bool) {
        guard lastAutoStartFailureMessage != message else { return }
        lastAutoStartFailureMessage = message
        systemIntegration.postAutoStartFailureNotification(for: item, message: message, enabled: enabled)
    }

    public func cancelRunningItem(id: String) {
        let itemBeforeCancel = items.first(where: { $0.id == id })
        lodyMonitorTasks[id]?.cancel()
        lodyMonitorTasks.removeValue(forKey: id)
        runRegistry.cancel(itemID: id)
        restorePendingOnCancel(itemID: id)
        if let itemBeforeCancel {
            cancelRemoteLodyTurnIfNeeded(for: itemBeforeCancel)
        }
    }

    /// 停止自动开始的审查并切回「待确认」卡片，便于更换 Lody Agent / 模型 / 模板后重新派发
    public func stopAndReconfigureItem(id: String) {
        let itemBeforeCancel = items.first(where: { $0.id == id })
        lodyMonitorTasks[id]?.cancel()
        lodyMonitorTasks.removeValue(forKey: id)
        runRegistry.cancel(itemID: id)
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].status = .pendingConfirmation
        items[idx].progressMessage = nil
        items[idx].errorMessage = nil
        items[idx].remoteSessionStatus = nil
        items[idx].sessionHandle = nil
        items[idx].sessionID = nil
        items[idx].executionOutput = nil
        items[idx].wasAutoStarted = false
        let updated = items[idx]
        if !isPreviewMode && !id.hasPrefix("demo-") {
            Task { await self.persistItem(updated) }
        }
        if let itemBeforeCancel {
            cancelRemoteLodyTurnIfNeeded(for: itemBeforeCancel)
        }
    }

    private func activeLodyHandleToCancel(for item: CollaborationItem) -> AgentSessionHandle? {
        guard let handle = item.sessionHandle,
              handle.engine == .lody,
              !handle.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        switch item.remoteSessionStatus {
        case .running, nil:
            return handle
        case .completed, .failed:
            return nil
        }
    }

    private func cancelRemoteLodyTurnIfNeeded(for item: CollaborationItem) {
        guard let handle = activeLodyHandleToCancel(for: item) else { return }
        let lodyConfig = settings.lodyConfig
        let envSnapshot = environment
        let canceller = backendFactory.makeSessionCanceller(config: lodyConfig)
        Task {
            do {
                try await canceller.cancelSession(handle, environment: envSnapshot)
            } catch {
                self.lastSystemNotice = L("Failed to cancel Lody session: %@", error.localizedDescription)
            }
        }
    }

    // MARK: - Helpers

    private func updateProgress(
        for ticket: ExecutionRunTicket,
        status: CollaborationTaskStatus,
        message: String
    ) {
        guard runRegistry.isCurrent(ticket), !ticket.isCancelled else { return }
        updateProgress(itemID: ticket.itemID, status: status, message: message)
    }

    private func updateProgress(itemID: String, status: CollaborationTaskStatus, message: String) {
        guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[idx].status = status
        items[idx].progressMessage = message
    }

    private func restorePendingOnCancel(itemID: String) {
        guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[idx].status = .pendingConfirmation
        items[idx].progressMessage = nil
    }

    /// 启动时恢复仍在运行中的 Lody 后台会话状态监听（兼顾升级前未记录 remoteSessionStatus 的进行中卡片）
    private func resumeActiveLodyMonitors() {
        guard !isPreviewMode else { return }
        for item in items where item.status == .draftReady && item.sessionHandle?.engine == .lody {
            guard let sid = item.sessionHandle?.sessionID ?? item.sessionID, !sid.isEmpty else { continue }
            if item.remoteSessionStatus == nil || item.remoteSessionStatus == .running {
                startMonitoringLodySession(
                    itemID: item.id,
                    sessionID: sid,
                    notifyEnabled: settings.notificationsEnabled
                )
            }
        }
    }

    /// 轻量后台轮询 `lody session show <id> --json`：实时更新卡片「审查中 → 审查完成」并自动回补用量账本
    private func startMonitoringLodySession(itemID: String, sessionID: String, notifyEnabled: Bool) {
        guard !isPreviewMode, !itemID.hasPrefix("demo-") else { return }
        lodyMonitorTasks[itemID]?.cancel()

        let task = Task { [weak self] in
            defer {
                self?.lodyMonitorTasks.removeValue(forKey: itemID)
            }
            for attempt in 0..<150 {
                if attempt > 0 {
                    try? await Task.sleep(for: .seconds(8))
                }
                guard !Task.isCancelled, let self else { return }
                guard let currentIdx = self.items.firstIndex(where: { $0.id == itemID }),
                      self.items[currentIdx].status == .draftReady else {
                    return
                }
                guard let lodyProbe = self.environment?.engines[.lody], lodyProbe.isInstalled else {
                    continue
                }

                let ws = self.settings.lodyConfig.workspace.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let snap = await self.detector.fetchLodySessionUsage(
                    lodyProbe: lodyProbe,
                    sessionID: sessionID,
                    workspace: ws.isEmpty ? nil : ws,
                    resolvedPATH: self.environment?.resolvedPATH
                ) else {
                    continue
                }

                guard !Task.isCancelled,
                      let idx = self.items.firstIndex(where: { $0.id == itemID }),
                      self.items[idx].status == .draftReady else {
                    return
                }

                let modelLabel = snap.modelName ?? snap.modelID ?? "Lody"
                if snap.isError {
                    self.items[idx].remoteSessionStatus = .failed
                    self.items[idx].executionOutput = .structuredReply(
                        StructuredReplyResult(
                            summary: L("Lody background session encountered an error. Click \"Open Lody\" to inspect."),
                            replyMarkdown: ""
                        )
                    )
                    let updated = self.items[idx]
                    await self.persistItem(updated)
                    return
                }

                if snap.isSettledIdle {
                    self.items[idx].remoteSessionStatus = .completed
                    let dispatchedAt = self.matchingLodyUsageRunIndex(itemID: itemID, sessionID: sessionID)
                        .map { self.usageRuns[$0].createdAt }
                    let roundDuration = dispatchedAt.flatMap { snap.roundDurationSeconds(since: $0) }
                        ?? (dispatchedAt == nil ? snap.durationSeconds : nil)
                    var parts: [String] = [L("%@ finished review", modelLabel)]
                    if let dur = roundDuration, dur > 0 {
                        parts.append(L("Duration %@", UsageAggregator.formatDuration(dur)))
                    }
                    if snap.contextUsedTokens > 0 {
                        parts.append(L("Context %@", UsageAggregator.formatCompactTokens(snap.contextUsedTokens)))
                    }
                    let summary = parts.joined(separator: " · ")
                    self.items[idx].executionOutput = .structuredReply(
                        StructuredReplyResult(summary: summary, replyMarkdown: "")
                    )
                    let updated = self.items[idx]
                    await self.persistItem(updated)
                    await self.applyLodySnapshotToUsageLedger(itemID: itemID, sessionID: sessionID, snapshot: snap)
                    self.systemIntegration.postCompletionNotification(
                        for: updated,
                        summary: summary,
                        enabled: notifyEnabled
                    )
                    return
                }

                // 仍在运行中：刷新实时上下文进度
                self.items[idx].remoteSessionStatus = .running
                let liveSummary: String
                if snap.contextUsedTokens > 0 {
                    liveSummary = L("%@ reviewing in background · Context %@", modelLabel, UsageAggregator.formatCompactTokens(snap.contextUsedTokens))
                } else {
                    liveSummary = L("%@ reviewing in background. Click \"Open Lody\" to view live progress.", modelLabel)
                }
                self.items[idx].executionOutput = .structuredReply(
                    StructuredReplyResult(summary: liveSummary, replyMarkdown: "")
                )
            }
        }
        lodyMonitorTasks[itemID] = task
    }

    private func matchingLodyUsageRunIndex(itemID: String, sessionID: String) -> Int? {
        if let exact = usageRuns.firstIndex(where: {
            $0.itemID == itemID && $0.sessionID == sessionID && !$0.id.hasPrefix("demo-usage-")
        }) {
            return exact
        }
        return usageRuns.firstIndex(where: {
            $0.sessionID == sessionID && !$0.id.hasPrefix("demo-usage-")
        })
    }

    private func applyLodySnapshotToUsageLedger(
        itemID: String,
        sessionID: String,
        snapshot snap: EnvironmentDetector.LodySessionUsageSnapshot
    ) async {
        guard let runIdx = matchingLodyUsageRunIndex(itemID: itemID, sessionID: sessionID) else {
            return
        }
        await applyLodySnapshot(snap, toRunAt: runIdx)
    }

    /// 统一的 Lody 快照落账逻辑（供 `syncPendingLodyUsage` 与实时监控共用）：
    /// - 耗时按本轮派发时间（`updated.createdAt`）计算
    /// - 续聊轮次仅记相对同会话更早且已同步轮次的新增上下文（若发生上下文压缩则回退记录当前上下文，绝不记负数）
    private func applyLodySnapshot(
        _ snap: EnvironmentDetector.LodySessionUsageSnapshot,
        toRunAt runIdx: Int
    ) async {
        var updated = usageRuns[runIdx]
        if let modelName = snap.modelName, !modelName.isEmpty {
            updated.model = modelName
        } else if let modelID = snap.modelID, !modelID.isEmpty {
            updated.model = modelID
        }
        let roundDuration = snap.roundDurationSeconds(since: updated.createdAt)
        if snap.contextUsedTokens > 0 {
            let roundContextTokens = effectiveLodyRoundContextTokens(
                for: updated,
                snapshotContextTokens: snap.contextUsedTokens
            )
            updated.usage = AgentUsageMetrics(
                totalTokens: roundContextTokens,
                durationSeconds: roundDuration ?? updated.usage.durationSeconds,
                metricKind: .contextWindow
            )
            updated.estimatedCostUSD = UsageCostEstimator.estimateUSD(
                model: snap.modelID ?? updated.model,
                engine: .lody,
                usage: updated.usage
            )
        }
        if snap.isSettledIdle && snap.contextUsedTokens > 0 {
            updated.syncedAt = clock.now
        }
        usageRuns[runIdx] = updated
        await persistUsageRun(updated)
    }

    private func effectiveLodyRoundContextTokens(
        for run: ReviewUsageRun,
        snapshotContextTokens: Int
    ) -> Int {
        guard snapshotContextTokens > 0,
              let sessionID = run.sessionID, !sessionID.isEmpty else {
            return max(0, snapshotContextTokens)
        }
        let priorSyncedTokens = usageRuns
            .filter { other in
                other.id != run.id
                    && !other.id.hasPrefix("demo-usage-")
                    && other.engine == .lody
                    && other.sessionID == sessionID
                    && other.syncedAt != nil
                    && other.createdAt < run.createdAt
            }
            .reduce(0) { $0 + $1.usage.totalTokens }
        guard priorSyncedTokens > 0 else {
            return snapshotContextTokens
        }
        let delta = snapshotContextTokens - priorSyncedTokens
        return delta >= 0 ? delta : snapshotContextTokens
    }

    private func runDemoSimulation(ticket: ExecutionRunTicket, targetItem: CollaborationItem, plan: ExecutionPlan) -> Task<Void, Never> {
        let itemID = ticket.itemID
        let agentName = lodyAgentConfigDisplayName(for: plan.lodyAgentConfig ?? settings.lodyConfig.defaultAgentConfig)
        updateProgress(for: ticket, status: .running, message: L("[Demo] Dispatching to Lody (%@)...", agentName))
        return Task {
            defer {
                self.runRegistry.finish(ticket)
            }
            try? await Task.sleep(for: .seconds(1.2))
            guard self.runRegistry.isCurrent(ticket), !ticket.isCancelled,
                  let idx = items.firstIndex(where: { $0.id == itemID }),
                  items[idx].status == .running else { return }
            items[idx].status = .draftReady
            items[idx].progressMessage = nil
            items[idx].remoteSessionStatus = .completed
            items[idx].sessionHandle = AgentSessionHandle(
                engine: .lody,
                sessionID: "demo-session-001",
                workspacePath: FileManager.default.homeDirectoryForCurrentUser.path,
                launchMode: .nativeBackgroundSession
            )
            items[idx].executionOutput = .structuredReply(
                StructuredReplyResult(
                    summary: L("[Demo] Real GitHub PRs will dispatch a Lody background session (%@) and track its progress and usage.", agentName),
                    replyMarkdown: ""
                )
            )
            selectedTab = .inbox
        }
    }

    private func persistSettings() {
        let snapshot = settings
        try? settingsStore.save(snapshot)
    }

    private static func makePreviewLodyCatalog() -> LodyCatalogSnapshot {
        LodyCatalogSnapshot(
            workspaceID: "preview-ws",
            workspaces: [
                LodyWorkspaceOption(id: "preview-ws", name: "dev's workspace", slug: "dev")
            ],
            agentConfigs: [
                LodyAgentConfigOption(
                    id: "lody-antigravity",
                    name: "Antigravity",
                    agentType: "antigravity",
                    models: [
                        ModelOption(id: "gemini-4-neon", displayName: "Gemini 4 Neon"),
                        ModelOption(id: "gemini-4-carbon", displayName: "Gemini 4 Carbon"),
                        ModelOption(id: "claude-opus-5-5", displayName: "Claude Opus 5.5")
                    ],
                    effortOptionKey: "thought_level",
                    reasoningEffortValues: ["low", "medium", "high", "xhigh"],
                    readOnlyModeID: "plan"
                ),
                LodyAgentConfigOption(
                    id: "lody-claude",
                    name: "Claude Code",
                    agentType: "claude",
                    models: [
                        ModelOption(id: "default", displayName: "Default (recommended)"),
                        ModelOption(id: "opus", displayName: "Opus 5.5"),
                        ModelOption(id: "sonnet", displayName: "Sonnet 5.5")
                    ],
                    effortOptionKey: "effort",
                    reasoningEffortValues: ["low", "medium", "high", "xhigh", "max"],
                    readOnlyModeID: "plan"
                ),
                LodyAgentConfigOption(
                    id: "lody-codex",
                    name: "Codex",
                    agentType: "codex",
                    models: [
                        ModelOption(id: "gpt-6.2-sol", displayName: "6.2 Sol"),
                        ModelOption(id: "gpt-6.2-astra", displayName: "6.2 Astra")
                    ],
                    effortOptionKey: "reasoning_effort",
                    reasoningEffortValues: ["low", "medium", "high", "xhigh", "max"],
                    readOnlyModeID: "read-only"
                )
            ],
            localProjects: [
                LodyLocalProjectOption(
                    id: "preview-proj-backend",
                    name: "backend",
                    rootPath: "/Users/dev/code/backend",
                    repositoryFullName: "acme/backend"
                ),
                LodyLocalProjectOption(
                    id: "preview-proj-web",
                    name: "web",
                    rootPath: "/Users/dev/code/web",
                    repositoryFullName: "acme/web"
                ),
                LodyLocalProjectOption(
                    id: "preview-proj-web-2",
                    name: "web-2",
                    rootPath: "/Users/dev/code/web-2",
                    repositoryFullName: "acme/web"
                )
            ]
        )
    }

    private static func makePreviewUsageRuns() -> [ReviewUsageRun] {
        let now = Date()
        let cal = Calendar.current
        func daysAgo(_ d: Int, hours: Int = 2) -> Date {
            cal.date(byAdding: .hour, value: -(d * 24 + hours), to: now) ?? now
        }
        return [
            ReviewUsageRun(
                id: "demo-usage-1",
                itemID: "demo-gh-482",
                platform: .github,
                scope: "acme/web",
                externalRef: "#4790",
                title: "perf(record): optimize text date formatting and wide-row copies",
                reviewRound: 2,
                continuityMode: .continueSessionIncremental,
                engine: .lody,
                lodyAgentName: "Antigravity",
                model: "Gemini 4 Neon",
                effort: .high,
                sessionID: "ses_demo_1",
                usage: AgentUsageMetrics(totalTokens: 96_400, durationSeconds: 38, metricKind: .contextWindow),
                createdAt: daysAgo(0, hours: 1),
                syncedAt: now
            ),
            ReviewUsageRun(
                id: "demo-usage-2",
                itemID: "demo-gh-2735",
                platform: .github,
                scope: "acme/web",
                externalRef: "#2735",
                title: "fix(workspace): organize shared projects under their team",
                reviewRound: 1,
                engine: .lody,
                lodyAgentName: "Claude Code",
                model: "Opus 5.5",
                effort: .high,
                sessionID: "ses_demo_2",
                usage: AgentUsageMetrics(totalTokens: 133_400, durationSeconds: 31, metricKind: .contextWindow),
                createdAt: daysAgo(1, hours: 3),
                syncedAt: now
            ),
            ReviewUsageRun(
                id: "demo-usage-3",
                itemID: "demo-lody-1",
                platform: .github,
                scope: "acme/cli",
                externalRef: "#1",
                title: "fix(cli): compare an unrecorded base against the remote default branch",
                reviewRound: 1,
                engine: .lody,
                lodyAgentName: "Antigravity",
                model: "Gemini 4 Neon",
                effort: .medium,
                sessionID: "11111111-2222-4333-8444-555555555555",
                usage: AgentUsageMetrics(totalTokens: 84_855, durationSeconds: 42, metricKind: .contextWindow),
                createdAt: daysAgo(1, hours: 6),
                syncedAt: now
            ),
            ReviewUsageRun(
                id: "demo-usage-4",
                itemID: "demo-gh-305",
                platform: .github,
                scope: "acme/infra",
                externalRef: "#990",
                title: "feat(envoy-gateway): staging admin domain restriction",
                reviewRound: 1,
                engine: .lody,
                lodyAgentName: "Antigravity",
                model: "Gemini 3.8 Flash",
                effort: .low,
                sessionID: "ses_demo_4",
                usage: AgentUsageMetrics(totalTokens: 33_450, durationSeconds: 14, metricKind: .contextWindow),
                createdAt: daysAgo(2, hours: 2),
                syncedAt: now
            ),
            ReviewUsageRun(
                id: "demo-usage-5",
                itemID: "demo-gh-4729",
                platform: .github,
                scope: "acme/web",
                externalRef: "#4729",
                title: "feat(app): cap app preview sandboxes per space",
                reviewRound: 1,
                engine: .lody,
                lodyAgentName: "Codex",
                model: "6.2 Sol",
                effort: .high,
                sessionID: "ses_demo_5",
                usage: AgentUsageMetrics(totalTokens: 119_200, durationSeconds: 29, metricKind: .contextWindow),
                createdAt: daysAgo(4, hours: 4),
                syncedAt: now
            )
        ]
    }

    private static func makePreviewItems() -> [CollaborationItem] {
        [
            CollaborationItem(
                id: "demo-gh-482",
                platform: .github,
                itemKind: .pullRequest,
                scope: "acme/backend",
                externalRef: "#482",
                title: "feat(auth): migrate JWT verification to JWKS cache",
                url: URL(string: "https://github.com/acme/backend/pull/482")!,
                author: "alice",
                triggeredBy: "alice",
                triggerKind: .mention,
                triggerBody: L("@dev please review the auth boundaries and cache invalidation --focus security"),
                payload: .codeChange(
                    CodeChangePayload(
                        repository: "acme/backend",
                        number: 482,
                        baseRef: "main",
                        headRef: "feat/jwks-cache",
                        headSHA: "a1b2c3d",
                        additions: 312,
                        deletions: 48,
                        changedFiles: 9
                    )
                ),
                suggestedPresetID: "code-review-security"
            ),
            CollaborationItem(
                id: "demo-gh-191",
                platform: .github,
                itemKind: .pullRequest,
                scope: "acme/web-console",
                externalRef: "#191",
                title: "fix(table): preserve column widths on workspace switch",
                url: URL(string: "https://github.com/acme/web-console/pull/191")!,
                author: "bob",
                triggeredBy: "bob",
                triggerKind: .reviewRequested,
                triggerBody: nil,
                payload: .codeChange(
                    CodeChangePayload(
                        repository: "acme/web-console",
                        number: 191,
                        baseRef: "main",
                        headRef: "fix/column-widths",
                        headSHA: "f9e8d7c",
                        additions: 64,
                        deletions: 21,
                        changedFiles: 3
                    )
                )
            ),
            CollaborationItem(
                id: "demo-feishu-oncall",
                platform: .feishu,
                itemKind: .conversation,
                scope: L("#payments-oncall"),
                externalRef: L("Thread"),
                title: L("Intermittent 504 on production callbacks, suspected retry queue backlog"),
                url: URL(string: "https://open.feishu.cn/")!,
                author: "diana",
                triggeredBy: "diana",
                triggerKind: .mention,
                triggerBody: L("@dev please check if webhook callback timeouts are looping on retries"),
                payload: .conversation(
                    ConversationPayload(
                        channelName: L("#payments-oncall"),
                        threadID: "om_991827",
                        recentSnippets: [
                            L("p99 rose to 8.2s over the last 10 minutes"),
                            L("Logs point to webhook_dispatcher.go")
                        ],
                        linkedRepository: "acme/backend"
                    )
                ),
                suggestedPresetID: "triage-root-cause"
            ),
            CollaborationItem(
                id: "demo-gh-305",
                platform: .github,
                itemKind: .pullRequest,
                scope: "acme/sync-engine",
                externalRef: "#305",
                title: "perf(queue): batch webhook flush with backpressure cap",
                url: URL(string: "https://github.com/acme/sync-engine/pull/305")!,
                author: "charlie",
                triggeredBy: "charlie",
                triggerKind: .mention,
                triggerBody: L("@dev please review the batch backpressure logic"),
                payload: .codeChange(
                    CodeChangePayload(
                        repository: "acme/sync-engine",
                        number: 305,
                        baseRef: "main",
                        headRef: "perf/batch-flush",
                        headSHA: "c0ffee1",
                        additions: 148,
                        deletions: 39,
                        changedFiles: 5
                    )
                ),
                status: .draftReady,
                progressMessage: L("Lody review complete · 54s · 142K ctx"),
                sessionID: "ses_demo_305",
                sessionHandle: AgentSessionHandle(
                    engine: .lody,
                    sessionID: "ses_demo_305",
                    workspacePath: "/Users/dev/code/sync-engine",
                    launchMode: .nativeBackgroundSession
                ),
                remoteSessionStatus: .completed
            )
        ]
    }
}
