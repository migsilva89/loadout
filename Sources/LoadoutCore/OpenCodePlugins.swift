import Foundation

/// opencode's plugins: the packages named in the `plugin` list of its config, and the scripts
/// sitting in its `plugins` folder.
///
/// opencode has no switch for a plugin — it loads whatever it finds — so these are listed, updated
/// and removed, but never turned off. The config is read directly rather than through
/// `opencode plugin list`, which starts a process and fetches version information over the network.
struct OpenCodePlugins {
    let paths: Paths

    /// `~/.config/opencode`, or wherever `XDG_CONFIG_HOME` put it.
    var home: URL { paths.opencodeConfig.deletingLastPathComponent() }

    func scan() -> [PluginInfo] {
        packages() + localPlugins()
    }

    private func packages() -> [PluginInfo] {
        guard let data = try? Data(contentsOf: paths.opencodeConfig),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        var seen = Set<String>()
        return Self.specs(in: root).compactMap { spec in
            guard seen.insert(spec).inserted else { return nil }
            let name = Self.name(of: spec)
            let installed = home.appendingPathComponent("node_modules/\(name)")
            let version = Self.pinnedVersion(of: spec) ?? Self.installedVersion(at: installed)
            return PluginInfo(
                id: "opencode:\(spec)", name: name, marketplace: Self.source(of: spec),
                version: version ?? "",
                installPath: FileManager.default.fileExists(atPath: installed.path) ? installed : home,
                enabled: true, assistant: "opencode", nativeKey: spec,
                toggleUnavailableReason: Self.noSwitch
            )
        }
    }

    private func localPlugins() -> [PluginInfo] {
        let fm = FileManager.default
        var result: [PluginInfo] = []
        for folder in ["plugins", "plugin"] {
            let root = home.appendingPathComponent(folder)
            let entries = (try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            )) ?? []
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                guard isDirectory || ["js", "ts", "mjs", "cjs", "tsx", "jsx"].contains(entry.pathExtension) else { continue }
                let file = entry.lastPathComponent
                result.append(PluginInfo(
                    id: "opencode:local:\(file)", name: entry.deletingPathExtension().lastPathComponent,
                    marketplace: "a file on this machine", version: "local", installPath: entry,
                    enabled: true, assistant: "opencode", nativeKey: "local:\(file)",
                    toggleUnavailableReason: Self.noSwitch
                ))
            }
        }
        return result
    }

    static let noSwitch = "opencode loads every plugin it finds and has no switch for one. Remove it to stop it loading."

    /// Entries of the `plugin` list: a string, or `[string, options]`.
    static func specs(in config: [String: Any]) -> [String] {
        (config["plugin"] as? [Any] ?? []).compactMap { entry in
            if let string = entry as? String { return string }
            return (entry as? [Any])?.first as? String
        }
    }

    /// The package name inside a spec: `pkg`, `pkg@1.2.3`, `@scope/pkg@1`, `pkg@git+https://…`,
    /// or a bare git URL, which is named after its repository.
    static func name(of spec: String) -> String {
        let scoped = spec.hasPrefix("@")
        let body = scoped ? String(spec.dropFirst()) : spec
        if let at = body.firstIndex(of: "@") {
            return (scoped ? "@" : "") + String(body[..<at])
        }
        if isRemote(spec) {
            let last = spec.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? spec
            return last.hasSuffix(".git") ? String(last.dropLast(4)) : last
        }
        return spec
    }

    /// `1.2.3` from `pkg@1.2.3`; nil for a tag like `latest` or a git source, where the version is
    /// whatever got installed.
    static func pinnedVersion(of spec: String) -> String? {
        let body = spec.hasPrefix("@") ? String(spec.dropFirst()) : spec
        guard let at = body.firstIndex(of: "@") else { return nil }
        let version = String(body[body.index(after: at)...])
        return version.first?.isNumber == true && !version.contains("/") ? version : nil
    }

    static func isRemote(_ spec: String) -> Bool {
        spec.contains("://") || spec.hasPrefix("git+") || spec.hasPrefix("github:") || spec.contains("git@")
    }

    static func source(of spec: String) -> String { isRemote(spec) ? "git" : "npm" }

    static func installedVersion(at folder: URL) -> String? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("package.json")),
              let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return package["version"] as? String
    }
}
