import Foundation

/// Reads registered marketplaces and the facts the classifier needs for rule P6.
public struct MarketplaceReader: Sendable {
    private let fs: any ReadonlyFileSystem

    public init(fileSystem: any ReadonlyFileSystem) {
        self.fs = fileSystem
    }

    /// `known_marketplaces.json`: an object keyed by marketplace name with `source` and `installLocation`
    /// [V field names; exact nesting of `source` is an assumption until spike S3 confirms it].
    /// `source` may be a string or an object such as `{ "source": "directory", "path": "…" }`.
    public func readKnown(file: String) -> ([String: MarketplaceRecord], [Problem]) {
        let data: Data
        do {
            guard let read = try fs.readFile(file) else { return ([:], []) }
            data = read
        } catch {
            return ([:], [Problem(.error, "Cannot read marketplaces file", file: file)])
        }
        guard let value = try? JSONValue.parse(data), let object = value.objectValue else {
            return ([:], [Problem(.error, "Marketplaces file is not a JSON object; marketplaces unknown", file: file)])
        }

        var markets: [String: MarketplaceRecord] = [:]
        var problems: [Problem] = []
        for (name, entry) in object {
            let source = entry["source"]
            guard let kind = source?.stringValue ?? source?["source"]?.stringValue else {
                problems.append(
                    Problem(.warning, "Marketplace \"\(name)\" has no readable source; treated as read-only", file: file))
                markets[name] = MarketplaceRecord(
                    name: name, source: .other("unknown"),
                    path: entry["installLocation"]?.stringValue)
                continue
            }
            let path = source?["path"]?.stringValue ?? entry["installLocation"]?.stringValue
            markets[name] = MarketplaceRecord(name: name, source: MarketplaceSource(rawValue: kind), path: path)
        }
        return (markets, problems)
    }

    /// Whether the marketplace entry for `pluginName` uses a relative-path `source` (`./…`),
    /// which makes the plugin load in place [V `plugins/loading`]. `nil` when it cannot be read.
    public func entrySourceIsRelative(market: MarketplaceRecord, pluginName: String) -> Bool? {
        guard let path = market.path else { return nil }
        let manifest = path.hasSuffix(".json") ? path : joinPath(path, ".claude-plugin", "marketplace.json")
        guard let data = try? fs.readFile(manifest), let value = try? JSONValue.parse(data),
            let plugins = value["plugins"]?.arrayValue
        else { return nil }
        guard let entry = plugins.first(where: { $0["name"]?.stringValue == pluginName }) else { return nil }
        guard let source = entry["source"]?.stringValue else { return false }
        return source.hasPrefix("./") || source.hasPrefix("../")
    }

    /// `remote "origin"` URL from `<folder>/.git/config`, credentials masked.
    public func gitRemote(folder: String) -> String? {
        guard let data = try? fs.readFile(joinPath(folder, ".git", "config")) else { return nil }
        var inOrigin = false
        for raw in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inOrigin = line == "[remote \"origin\"]"
                continue
            }
            if inOrigin, line.hasPrefix("url") {
                let parts = line.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                return Redactor.maskURL(parts[1].trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }
}
