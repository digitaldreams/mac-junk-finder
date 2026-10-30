import Foundation

public enum SkipKind: Sendable, Equatable { case protected, owner, cloudOnly, mountPoint, other }

public struct Skipped: Sendable, Equatable {
    public var path: String   // relative to the scan root
    public var kind: SkipKind
}

public struct Finding: Sendable {
    public var item: Item
    public var match: Match
}

public struct ScanResult: Sendable {
    public var findings: [Finding] = []
    public var skipped: [Skipped] = []
}

public func classifyScanError(_ error: Error) -> SkipKind {
    let ns = error as NSError
    var posix: Int32?
    if ns.domain == NSPOSIXErrorDomain {
        posix = Int32(ns.code)
    } else if let u = ns.userInfo[NSUnderlyingErrorKey] as? NSError, u.domain == NSPOSIXErrorDomain {
        posix = Int32(u.code)
    }
    switch posix {
    case EPERM: return .protected
    case EACCES: return .owner
    case EDEADLK: return .cloudOnly
    default:
        // ponytail: Cocoa 257 with no POSIX cause is assumed to be plain permissions (owner).
        return ns.domain == NSCocoaErrorDomain && ns.code == 257 ? .owner : .other
    }
}

private let skipList: Set<String> = [
    "Library/Mobile Documents", "Library/CloudStorage", "Library/Containers", "Library/Group Containers",
    "Library/Mail", "Library/Messages", "Library/Safari", "Library/Cookies", "Library/Calendars",
    "Library/Keychains", "Library/Application Support", ".Trash", ".ssh", ".gnupg", ".aws", ".cache",
    ".config", ".local", ".rustup", ".nvm", ".cargo/bin", "go/bin", ".pyenv/versions", ".sbt/boot",
    ".stack/programs", "Pictures", "Music", "Desktop", "Documents",
]

// Only these names need sibling lookup (D4/D5/D6), so avoid listing every parent directory.
private let siblingSensitive: Set<String> = ["target", "node_modules", ".build", "vendor"]

private let keys: [URLResourceKey] = [
    .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey, .isRegularFileKey,
    .isSymbolicLinkKey, .isPackageKey, .linkCountKey, .fileIdentifierKey, .volumeIdentifierKey,
    .contentModificationDateKey, .addedToDirectoryDateKey,
]

private struct LinkKey: Hashable {
    let volume: NSObject
    let id: NSObject
}

private final class Scanner {
    let root: URL
    let rootPath: String
    let now: Date
    let rootVolume: NSObject?
    var result = ScanResult()
    var seenLinks = Set<LinkKey>()

    init(root: URL, now: Date) {
        self.root = root
        self.rootPath = root.path
        self.now = now
        self.rootVolume = (try? root.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
    }

    func relative(_ url: URL) -> String {
        url.path.hasPrefix(rootPath + "/") ? String(url.path.dropFirst(rootPath.count + 1)) : url.path
    }

    func record(_ url: URL, _ kind: SkipKind) {
        let rel = relative(url)
        if result.skipped.contains(where: { rel == $0.path || rel.hasPrefix($0.path + "/") }) { return }
        result.skipped.append(Skipped(path: rel, kind: kind))
    }

    /// Allocated bytes of a regular file, 0 for a hard link already counted.
    func allocated(_ v: URLResourceValues) -> Int64 {
        if let n = v.linkCount, n > 1, let vol = v.volumeIdentifier as? NSObject, let id = v.fileIdentifier as? NSObject {
            if !seenLinks.insert(LinkKey(volume: vol, id: id)).inserted { return 0 }
        }
        return Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
    }

    func enumerate(_ url: URL, options: FileManager.DirectoryEnumerationOptions) -> FileManager.DirectoryEnumerator? {
        FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: options) { [self] u, e in
            record(u, classifyScanError(e))
            return true
        }
    }

    func onOtherVolume(_ v: URLResourceValues) -> Bool {
        guard let rv = rootVolume, let vv = v.volumeIdentifier as? NSObject else { return false }
        return !rv.isEqual(vv)
    }

    /// Sums everything inside `url` and finds the newest regular-file mtime in one pass; symlinks are never
    /// followed or counted, and directories on another volume are recorded and skipped.
    func size(of url: URL) -> (bytes: Int64, newest: Date?) {
        guard let en = enumerate(url, options: []) else { return (0, nil) }
        var total: Int64 = 0
        var newest: Date?
        for case let u as URL in en {
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true else { continue }
            if v.isDirectory == true, onOtherVolume(v) { record(u, .mountPoint); en.skipDescendants(); continue }
            guard v.isRegularFile == true else { continue }
            total += allocated(v)
            if let m = v.contentModificationDate, m > (newest ?? .distantPast) { newest = m }
        }
        return (total, newest)
    }

    func run() -> ScanResult {
        guard let en = enumerate(root, options: [.skipsPackageDescendants]) else { return result }
        for case let url as URL in en {
            let rel = relative(url)
            if skipList.contains(rel) { en.skipDescendants(); continue }
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isSymbolicLink == true { continue }

            let kind: ItemKind
            if v.isPackage == true { kind = .package }
            else if v.isDirectory == true { kind = .dir }
            else if v.isRegularFile == true { kind = .file }
            else { continue }

            if kind != .file, onOtherVolume(v) {
                record(url, .mountPoint); en.skipDescendants(); continue
            }

            let name = url.lastPathComponent
            let siblings = siblingSensitive.contains(name)
                ? ((try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? []) : []
            var item = Item(path: rel, kind: kind, siblings: siblings, size: kind == .file ? allocated(v) : 0,
                            modified: v.contentModificationDate ?? now, dateAdded: v.addedToDirectoryDate)
            if kind == .package || kind == .dir {
                // Directory rules do not depend on size; size the subtree only after a match.
                if kind == .dir {
                    guard classify(item, now: now) != nil else { continue }
                    en.skipDescendants()
                }
                let (bytes, newest) = size(of: url)
                if bytes == 0 { continue }   // empty cache dirs are not findings
                item.size = bytes
                if let newest { item.modified = newest }
            }
            if let m = classify(item, now: now) { result.findings.append(Finding(item: item, match: m)) }
        }
        return result
    }
}

public func scan(root: URL, now: Date) -> ScanResult {
    Scanner(root: root.resolvingSymlinksInPath(), now: now).run()
}
