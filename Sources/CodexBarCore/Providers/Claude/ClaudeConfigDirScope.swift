import Foundation

public enum ClaudeConfigDirScope {
    public static func normalizedConfigDirPath(
        _ rawPath: String?,
        fileManager: FileManager = .default)
        -> String?
    {
        guard var path = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return nil
        }
        if path == "~" {
            path = fileManager.homeDirectoryForCurrentUser.path
        } else if path.hasPrefix("~/") {
            path = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(String(path.dropFirst(2)), isDirectory: true)
                .path
        } else if path.hasPrefix("~") {
            return nil
        }
        guard (path as NSString).isAbsolutePath else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

    /// Home-relative form for display and for portable `config.json` entries.
    public static func abbreviatedConfigDirPath(
        _ path: String,
        fileManager: FileManager = .default) -> String
    {
        let home = fileManager.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    public static func scopedEnvironment(base: [String: String], configDir: String?) -> [String: String] {
        guard let configDir, !configDir.isEmpty else { return base }
        var env = base
        env[ClaudeConfigPaths.configDirectoryEnvironmentKey] = configDir
        // An ambient secure-storage override would resolve credentials outside the selected profile.
        env.removeValue(forKey: ClaudeConfigPaths.secureStorageDirectoryEnvironmentKey)
        return env
    }
}
