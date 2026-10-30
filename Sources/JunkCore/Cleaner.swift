import Foundation

// This file is the only place allowed to call trashItem/removeItem. Junk tier only, after the caller's
// confirmation and per-item re-checks.

public enum CleanSection: String, Sendable, CaseIterable { case caches, logs, dev, installers }

public struct CleanOptions: Sendable, Equatable {
    public var sections: [CleanSection]
    public var yes: Bool
    public var permanent: Bool
}

public struct CleanArgError: Error, Sendable, Equatable { public var message: String }

public let cleanUsage = "Usage: junk clean <caches|logs|dev|installers>... [--yes] [--permanent]"

/// `args` are the arguments after `clean`.
public func parseCleanArgs(_ args: [String]) -> Result<CleanOptions, CleanArgError> {
    var o = CleanOptions(sections: [], yes: false, permanent: false)
    for a in args {
        switch a {
        case "--yes": o.yes = true
        case "--permanent": o.permanent = true
        case "big": return .failure(CleanArgError(message: "Big files are Review only; delete them by hand"))
        default:
            guard let s = CleanSection(rawValue: a) else { return .failure(CleanArgError(message: "Unknown argument '\(safe(a))'.\n\(cleanUsage)")) }
            if !o.sections.contains(s) { o.sections.append(s) }
        }
    }
    if o.sections.isEmpty { return .failure(CleanArgError(message: cleanUsage)) }
    return .success(o)
}

private func sectionRules(_ s: CleanSection) -> Set<String> {
    switch s {
    case .caches: ["C1"]
    case .logs: ["C2"]
    case .dev: ["D1", "D3"]
    case .installers: ["I1"]
    }
}

public typealias CleanPlan = (remove: [Finding], skipped: [(finding: Finding, reason: String)])

public func cleanPlan(_ result: ScanResult, sections: Set<CleanSection>, runningBundleIDs: Set<String>) -> CleanPlan {
    let rules = sections.reduce(into: Set<String>()) { $0.formUnion(sectionRules($1)) }
    var plan: CleanPlan = ([], [])
    for f in result.findings where f.match.tier == .junk && rules.contains(f.match.ruleID) {
        let running = (f.match.ruleID == "C1" && runningBundleIDs.contains((f.item.path as NSString).lastPathComponent))
            || (f.match.ruleID == "D1" && runningBundleIDs.contains("com.apple.dt.Xcode"))
        if running { plan.skipped.append((f, "app running")) } else { plan.remove.append(f) }
    }
    return plan
}

/// nil when the item may be removed, otherwise why not. `root` must be symlink-resolved.
public func recheck(_ f: Finding, root: URL) -> String? {
    let parts = f.item.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    if parts.isEmpty || parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) { return "path is not under the root" }
    var rootStat = stat()
    guard lstat(root.path, &rootStat) == 0 else { return "root is not readable" }
    var current = root
    for (i, part) in parts.enumerated() {
        current.appendPathComponent(part)
        var st = stat()
        if lstat(current.path, &st) != 0 { return i == parts.count - 1 ? "no longer exists" : "parent no longer exists" }
        if st.st_mode & S_IFMT == S_IFLNK { return i == parts.count - 1 ? "is now a symlink" : "parent is now a symlink" }
        if st.st_dev != rootStat.st_dev { return "on another volume" }
    }
    if current.resolvingSymlinksInPath().path != current.path { return "resolved path differs" }
    return nil
}

public struct CleanOutcome {
    public var removed: [Finding] = []
    public var skipped: [(finding: Finding, reason: String)] = []
    public var failed: [(finding: Finding, reason: String)] = []
    public var trashedURLs: [URL] = []
}

// ponytail: re-check and removal are separate syscalls, so a swap in between is still possible; closing
// that needs openat/unlinkat-style removal, which FileManager does not offer.
public func performClean(_ findings: [Finding], root: URL, permanent: Bool) -> CleanOutcome {
    var out = CleanOutcome()
    let fm = FileManager.default
    for f in findings {
        guard f.match.tier == .junk else { out.skipped.append((f, "not Junk tier")); continue }
        if let why = recheck(f, root: root) { out.skipped.append((f, why)); continue }
        let url = root.appendingPathComponent(f.item.path)
        do {
            if permanent {
                try fm.removeItem(at: url)
            } else {
                var result: NSURL?
                try fm.trashItem(at: url, resultingItemURL: &result)
                if let r = result as URL? { out.trashedURLs.append(r) }
            }
            out.removed.append(f)
        } catch {
            out.failed.append((f, error.localizedDescription))
        }
    }
    return out
}

// MARK: text

private func totalSize(_ fs: [Finding]) -> Int64 { fs.reduce(0) { $0 + $1.item.size } }

public func renderCleanPlan(remove: [Finding], skipped: [(finding: Finding, reason: String)]) -> String {
    var out = "To remove:\n"
    for f in remove.sorted(by: { $0.item.size > $1.item.size }) {
        out += "  \(formatSize(f.item.size))  ~/\(safe(f.item.path))\n"
    }
    out += "Skipped:\n"
    for (f, why) in skipped { out += "  ~/\(safe(f.item.path))  (skipped: \(why))\n" }
    out += "Total: \(remove.count) items (\(formatSize(totalSize(remove))))"
    return out
}

public func cleanPrompt(count: Int, bytes: Int64, permanent: Bool) -> String {
    permanent
        ? "Permanently delete \(count) items (\(formatSize(bytes)))? This cannot be undone. [y/N] "
        : "Move \(count) items (\(formatSize(bytes))) to Trash? [y/N] "
}

public func isConfirmed(_ answer: String?) -> Bool {
    guard let a = answer?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
    return a == "y" || a == "yes"
}

/// `extraSkipped` counts items left out by the plan (running apps), added to those skipped by re-checks.
public func cleanSummary(_ o: CleanOutcome, extraSkipped: Int, permanent: Bool) -> String {
    let verb = permanent ? "Deleted" : "Moved"
    var s = "\(verb) \(o.removed.count) items (\(formatSize(totalSize(o.removed))))\(permanent ? "" : " to Trash"); "
        + "\(o.skipped.count + extraSkipped) skipped; \(o.failed.count) failed."
    if !permanent { s += "\nSpace is freed when you empty the Trash." }
    return s
}

public func cleanExitCode(_ o: CleanOutcome) -> Int32 { o.failed.isEmpty ? 0 : 1 }
