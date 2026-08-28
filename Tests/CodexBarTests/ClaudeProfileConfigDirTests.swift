import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeProfileConfigDirTests {
    @MainActor
    private static func makeSettings(suite: String) throws -> SettingsStore {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: "providerDetectionCompleted")
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.providerDetectionCompleted = true
        return settings
    }

    @Test
    func `legacy config without claude profile keys decodes to nil`() throws {
        let legacyJSON = """
        {
            "version": 1,
            "providers": [
                {
                    "id": "claude"
                }
            ]
        }
        """

        let decoded = try JSONDecoder().decode(CodexBarConfig.self, from: Data(legacyJSON.utf8))

        #expect(decoded.providerConfig(for: .claude)?.claudeActiveSource == nil)
        #expect(decoded.providerConfig(for: .claude)?.claudeProfileConfigDirs == nil)
    }

    @Test
    func `provider config round trips profile config dirs and active source`() throws {
        var provider = ProviderConfig(id: .claude)
        provider.claudeProfileConfigDirs = ["~/.claude-work", "/tmp/claude-personal"]
        provider.claudeActiveSource = .profileConfigDir(path: "~/.claude-work")
        let config = CodexBarConfig(providers: [provider])

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(CodexBarConfig.self, from: data)

        #expect(decoded.providerConfig(for: .claude)?.claudeProfileConfigDirs ==
            ["~/.claude-work", "/tmp/claude-personal"])
        #expect(decoded.providerConfig(for: .claude)?.claudeActiveSource ==
            .profileConfigDir(path: "~/.claude-work"))
    }

    @Test
    func `active source with blank path decodes to ambient`() throws {
        let json = """
        {
            "version": 1,
            "providers": [
                {
                    "id": "claude",
                    "claudeActiveSource": { "kind": "profileConfigDir", "configDirPath": "  " }
                }
            ]
        }
        """

        let decoded = try JSONDecoder().decode(CodexBarConfig.self, from: Data(json.utf8))

        #expect(decoded.providerConfig(for: .claude)?.claudeActiveSource == .ambient)
    }

    @Test
    func `unknown active source kind fails soft`() throws {
        let json = """
        {
            "version": 1,
            "providers": [
                {
                    "id": "claude",
                    "claudeActiveSource": { "kind": "futureKind" }
                }
            ]
        }
        """

        let decoded = try JSONDecoder().decode(CodexBarConfig.self, from: Data(json.utf8))

        #expect(decoded.providerConfig(for: .claude)?.claudeActiveSource == nil)
    }

    @Test
    func `config dir normalization expands tilde and rejects relative paths`() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        #expect(ClaudeConfigDirScope.normalizedConfigDirPath("~/.claude-work") == "\(home)/.claude-work")
        #expect(ClaudeConfigDirScope.normalizedConfigDirPath("~") == home)
        #expect(ClaudeConfigDirScope.normalizedConfigDirPath("/tmp/claude//") == "/tmp/claude")
        #expect(ClaudeConfigDirScope.normalizedConfigDirPath("relative/path") == nil)
        #expect(ClaudeConfigDirScope.normalizedConfigDirPath("~user/claude") == nil)
        #expect(ClaudeConfigDirScope.normalizedConfigDirPath("   ") == nil)
        #expect(ClaudeConfigDirScope.normalizedConfigDirPath(nil) == nil)
    }

    @Test
    func `scoped environment sets config dir and drops secure storage override`() {
        let base = [
            "HOME": "/Users/example",
            ClaudeConfigPaths.configDirectoryEnvironmentKey: "/Users/example/.claude",
            ClaudeConfigPaths.secureStorageDirectoryEnvironmentKey: "/Users/example/.claude-secure",
        ]

        let scoped = ClaudeConfigDirScope.scopedEnvironment(base: base, configDir: "/tmp/claude-work")

        #expect(scoped[ClaudeConfigPaths.configDirectoryEnvironmentKey] == "/tmp/claude-work")
        #expect(scoped[ClaudeConfigPaths.secureStorageDirectoryEnvironmentKey] == nil)
        #expect(scoped["HOME"] == "/Users/example")
        #expect(ClaudeConfigDirScope.scopedEnvironment(base: base, configDir: nil) == base)
    }

    @Test
    func `claude keychain service targets the profile-suffixed item for custom config dirs`() {
        let base = ["HOME": "/Users/example"]

        #expect(ClaudeOAuthCredentialsStore.claudeKeychainService(environment: base) ==
            "Claude Code-credentials")
        // Claude Code stores an explicitly configured default root in the bare item too.
        #expect(ClaudeOAuthCredentialsStore.claudeKeychainService(
            environment: base.merging(
                [ClaudeConfigPaths.configDirectoryEnvironmentKey: "/Users/example/.claude"],
                uniquingKeysWith: { _, new in new })) ==
            "Claude Code-credentials")
        // Suffix is the first 8 hex chars of SHA-256 of the absolute config dir path.
        #expect(ClaudeOAuthCredentialsStore.claudeKeychainService(
            environment: base.merging(
                [ClaudeConfigPaths.configDirectoryEnvironmentKey: "/tmp/claude-work"],
                uniquingKeysWith: { _, new in new })) ==
            "Claude Code-credentials-bfc1769a")
    }

    @Test
    func `claude cost cache scope key partitions custom config dirs only`() {
        let base = ["HOME": "/Users/example"]

        #expect(CostUsageScanner.claudeCacheScopeKey(environment: base) == nil)
        // An explicitly configured default root stays in the legacy unsuffixed cache.
        #expect(CostUsageScanner.claudeCacheScopeKey(
            environment: base.merging(
                [ClaudeConfigPaths.configDirectoryEnvironmentKey: "/Users/example/.claude"],
                uniquingKeysWith: { _, new in new })) == nil)
        // Same suffix convention as the profile Keychain item: first 8 hex chars of SHA-256 of the root.
        #expect(CostUsageScanner.claudeCacheScopeKey(
            environment: base.merging(
                [ClaudeConfigPaths.configDirectoryEnvironmentKey: "/tmp/claude-work"],
                uniquingKeysWith: { _, new in new })) == "bfc1769a")
    }

    @Test
    func `claude cost cache file is partitioned by scope key`() {
        let root = URL(fileURLWithPath: "/tmp/codexbar-cache-test", isDirectory: true)

        #expect(CostUsageClaudeCacheIO.cacheFileURL(provider: .claude, cacheRoot: root).lastPathComponent ==
            "claude-v6.json")
        #expect(CostUsageClaudeCacheIO.cacheFileURL(
            provider: .claude,
            cacheRoot: root,
            scopeKey: "bfc1769a").lastPathComponent ==
            "claude-v6-bfc1769a.json")
    }

    @Test
    @MainActor
    func `settings store normalizes and deduplicates profile config dirs`() throws {
        let suite = "ClaudeProfileConfigDirTests-normalization"
        let settings = try Self.makeSettings(suite: suite)
        settings.updateProviderConfig(provider: .claude) { entry in
            entry.claudeProfileConfigDirs = [
                "/tmp/claude-work",
                "/tmp/claude-work/",
                "relative/ignored",
                "~/.claude-personal",
            ]
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(settings.claudeProfileConfigDirs == ["/tmp/claude-work", "\(home)/.claude-personal"])
    }

    @Test
    @MainActor
    func `resolved active source falls back to ambient when dir leaves the allow-list`() throws {
        let suite = "ClaudeProfileConfigDirTests-fallback"
        let settings = try Self.makeSettings(suite: suite)
        settings.updateProviderConfig(provider: .claude) { entry in
            entry.claudeProfileConfigDirs = ["/tmp/claude-work"]
            entry.claudeActiveSource = .profileConfigDir(path: "/tmp/claude-work")
        }

        #expect(settings.claudeResolvedActiveSource == .profileConfigDir(path: "/tmp/claude-work"))

        settings.updateProviderConfig(provider: .claude) { entry in
            entry.claudeProfileConfigDirs = []
        }

        #expect(settings.claudeResolvedActiveSource == .ambient)
        #expect(settings.profileClaudeConfigDir(
            forActiveSource: .profileConfigDir(path: "/tmp/claude-work")) == nil)
    }

    @Test
    @MainActor
    func `adding profile config dirs normalizes stores and rejects duplicates`() throws {
        let suite = "ClaudeProfileConfigDirTests-add"
        let settings = try Self.makeSettings(suite: suite)
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        #expect(settings.addClaudeProfileConfigDir("\(home)/.claude-work") == true)
        #expect(settings.addClaudeProfileConfigDir("~/.claude-work") == false)
        #expect(settings.addClaudeProfileConfigDir("relative/rejected") == false)
        #expect(settings.addClaudeProfileConfigDir("/tmp/claude-other") == true)

        #expect(settings.claudeProfileConfigDirs == ["\(home)/.claude-work", "/tmp/claude-other"])
        // Home-relative entries stay portable in config.json.
        #expect(settings.configSnapshot.providerConfig(for: .claude)?.claudeProfileConfigDirs ==
            ["~/.claude-work", "/tmp/claude-other"])
    }

    @Test
    @MainActor
    func `removing the selected profile config dir falls back to ambient`() throws {
        let suite = "ClaudeProfileConfigDirTests-remove"
        let settings = try Self.makeSettings(suite: suite)
        settings.addClaudeProfileConfigDir("/tmp/claude-work")
        settings.addClaudeProfileConfigDir("/tmp/claude-other")
        settings.claudeActiveSource = .profileConfigDir(path: "/tmp/claude-work")

        settings.removeClaudeProfileConfigDir("/tmp/claude-work")

        #expect(settings.claudeProfileConfigDirs == ["/tmp/claude-other"])
        #expect(settings.claudeActiveSource == .ambient)
        #expect(settings.claudeResolvedActiveSource == .ambient)

        settings.removeClaudeProfileConfigDir("/tmp/claude-other")
        #expect(settings.claudeProfileConfigDirs.isEmpty)
        #expect(settings.configSnapshot.providerConfig(for: .claude)?.claudeProfileConfigDirs == nil)
    }

    @Test
    @MainActor
    func `removing an unselected profile config dir keeps the selection`() throws {
        let suite = "ClaudeProfileConfigDirTests-remove-unselected"
        let settings = try Self.makeSettings(suite: suite)
        settings.addClaudeProfileConfigDir("/tmp/claude-work")
        settings.addClaudeProfileConfigDir("/tmp/claude-other")
        settings.claudeActiveSource = .profileConfigDir(path: "/tmp/claude-work")

        settings.removeClaudeProfileConfigDir("/tmp/claude-other")

        #expect(settings.claudeProfileConfigDirs == ["/tmp/claude-work"])
        #expect(settings.claudeResolvedActiveSource == .profileConfigDir(path: "/tmp/claude-work"))
    }

    @MainActor
    private static func claudeMenuSubmenus(
        settings: SettingsStore) -> [(String, [MenuDescriptor.SubmenuItem])]
    {
        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        return MenuDescriptor.build(
            provider: .claude,
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updateReady: false)
            .sections
            .flatMap(\.entries)
            .compactMap { entry in
                guard case let .submenu(title, _, items) = entry else { return nil }
                return (title, items)
            }
    }

    @Test
    @MainActor
    func `claude menu offers account directory submenu with active checkmark`() throws {
        let suite = "ClaudeProfileConfigDirTests-menu"
        let settings = try Self.makeSettings(suite: suite)
        settings.updateProviderConfig(provider: .claude) { entry in
            entry.claudeProfileConfigDirs = ["/tmp/claude-work", "/tmp/claude-other"]
            entry.claudeActiveSource = .profileConfigDir(path: "/tmp/claude-work")
        }

        let submenu = try #require(Self.claudeMenuSubmenus(settings: settings)
            .first(where: { $0.0 == "Account Directory" }))

        #expect(submenu.1.map(\.title) == ["Default (~/.claude)", "/tmp/claude-work", "/tmp/claude-other"])
        #expect(submenu.1.map(\.isChecked) == [false, true, false])
        #expect(submenu.1.map(\.isEnabled) == [true, false, true])
        #expect(submenu.1.map(\.action) == [
            .selectClaudeProfileDir(path: nil),
            .selectClaudeProfileDir(path: "/tmp/claude-work"),
            .selectClaudeProfileDir(path: "/tmp/claude-other"),
        ])
    }

    @Test
    @MainActor
    func `claude menu hides account directory submenu without configured dirs`() throws {
        let suite = "ClaudeProfileConfigDirTests-menu-hidden"
        let settings = try Self.makeSettings(suite: suite)

        let hasSubmenu = Self.claudeMenuSubmenus(settings: settings)
            .contains { $0.0 == "Account Directory" }

        #expect(hasSubmenu == false)
    }

    @Test
    @MainActor
    func `provider registry scopes selected claude profile config dir`() throws {
        let suite = "ClaudeProfileConfigDirTests-routing"
        let settings = try Self.makeSettings(suite: suite)
        settings.updateProviderConfig(provider: .claude) { entry in
            entry.claudeProfileConfigDirs = ["/tmp/claude-work"]
            entry.claudeActiveSource = .profileConfigDir(path: "/tmp/claude-work")
        }

        let environment = ProviderRegistry.makeEnvironment(
            base: [
                ClaudeConfigPaths.configDirectoryEnvironmentKey: "/tmp/ambient-claude",
                ClaudeConfigPaths.secureStorageDirectoryEnvironmentKey: "/tmp/ambient-secure",
            ],
            provider: .claude,
            settings: settings,
            tokenOverride: nil)

        #expect(environment[ClaudeConfigPaths.configDirectoryEnvironmentKey] == "/tmp/claude-work")
        #expect(environment[ClaudeConfigPaths.secureStorageDirectoryEnvironmentKey] == nil)
    }

    @Test
    @MainActor
    func `provider registry leaves ambient claude environment untouched without a selection`() throws {
        let suite = "ClaudeProfileConfigDirTests-ambient"
        let settings = try Self.makeSettings(suite: suite)
        settings.updateProviderConfig(provider: .claude) { entry in
            entry.claudeProfileConfigDirs = ["/tmp/claude-work"]
        }

        let environment = ProviderRegistry.makeEnvironment(
            base: [ClaudeConfigPaths.configDirectoryEnvironmentKey: "/tmp/ambient-claude"],
            provider: .claude,
            settings: settings,
            tokenOverride: nil)

        #expect(environment[ClaudeConfigPaths.configDirectoryEnvironmentKey] == "/tmp/ambient-claude")
    }
}
