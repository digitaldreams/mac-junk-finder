import Foundation

/// 1000-based like Finder: "999 KB", "1.0 MB", "340 MB", "1.2 GB".
public func formatSize(_ bytes: Int64) -> String {
    if bytes < 1000 { return "\(bytes) B" }
    let units = ["KB", "MB", "GB", "TB"]
    var v = Double(bytes) / 1000
    var i = 0
    while true {
        // KB and values >= 100 show no decimals; a value that rounds up to 1000 moves to the next unit.
        let r1 = (v * 10).rounded() / 10
        let whole = i == 0 || r1 >= 100
        let r = whole ? v.rounded() : r1
        if r >= 1000, i < units.count - 1 { v /= 1000; i += 1; continue }
        return String(format: whole ? "%.0f %@" : "%.1f %@", r, units[i])
    }
}

private let sections: [(Category, String)] = [
    (.cachesAndLogs, "Caches & logs"), (.devJunk, "Dev junk"),
    (.oldInstallers, "Old installers"), (.bigFiles, "Big files"),
]

private let skipLabels: [(SkipKind, String)] = [
    (.protected, "protected by macOS privacy"), (.owner, "no permission"), (.cloudOnly, "cloud-only"),
    (.mountPoint, "other volume"), (.other, "unreadable, unknown error"),
]

private let maxNamed = 3

/// Paths come from the filesystem and may hold terminal escapes or newlines.
private func safe(_ path: String) -> String {
    String(String.UnicodeScalarView(path.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7F ? "?" : $0 }))
}

private func padLeft(_ s: String, _ n: Int) -> String { String(repeating: " ", count: max(0, n - s.count)) + s }
private func padRight(_ s: String, _ n: Int) -> String { s + String(repeating: " ", count: max(0, n - s.count)) }

private func age(_ f: Finding, now: Date) -> String {
    let item = f.item
    // I1 ages from date added (research); everything else from modified.
    let (label, date) = f.match.ruleID == "I1" && item.dateAdded != nil ? ("added", item.dateAdded!) : ("modified", item.modified)
    return "\(label) \(max(0, Int(now.timeIntervalSince(date) / 86_400))) d ago"
}

private func skippedLine(_ skipped: [Skipped]) -> String {
    let parts = skipLabels.compactMap { kind, label -> String? in
        let paths = skipped.filter { $0.kind == kind }.map(\.path)
        if paths.isEmpty { return nil }
        let named = paths.prefix(maxNamed).map { "~/\(safe($0))" }.joined(separator: ", ")
        return "\(paths.count) \(label) (\(named)\(paths.count > maxNamed ? ", ..." : ""))"
    }
    return parts.isEmpty ? "Skipped: none" : "Skipped (not counted, sizes incomplete): " + parts.joined(separator: "; ")
}

public func render(_ result: ScanResult, now: Date) -> String {
    var out = ""
    for (category, title) in sections {
        let rows = result.findings.filter { $0.match.category == category }.sorted { $0.item.size > $1.item.size }
        if rows.isEmpty { continue }
        out += "\(title)\n"
        for f in rows {
            out += "  \(padLeft(formatSize(f.item.size), 8))  \(padRight(f.match.tier == .junk ? "junk" : "review", 6))  "
                + "~/\(safe(f.item.path))  (\(age(f, now: now)))  \(f.match.ruleID): \(f.match.reason)\n"
        }
        out += "\n"
    }
    if result.findings.isEmpty { out += "No junk found.\n\n" }

    func total(_ t: Tier) -> Int64 { result.findings.filter { $0.match.tier == t }.reduce(0) { $0 + $1.item.size } }
    out += "Junk (reclaimable): \(formatSize(total(.junk)))\n"
    out += "Review (check before deleting): \(formatSize(total(.review)))\n\n"
    out += skippedLine(result.skipped) + "\n\n"
    out += """
    Notes
    - Sizes are allocated bytes (what the files occupy on disk), not logical sizes.
    - Hard links are counted once; clones are counted at full size, so real savings may be smaller.
    - Space held by local Time Machine snapshots is not freed until they expire (tmutil listlocalsnapshots /).
    - Finder and System Settings "Available" will not rise one-for-one; they use volume-level figures that will not match these totals.
    - Caches regenerate, and macOS purges many of them itself.
    - Skipped and built-in excluded areas are not scanned, so totals are a lower bound.
    - Not scanned by design: Trash, Mail, cloud folders, app containers, Application Support, Desktop, Documents, Pictures, Music.

    """
    return out
}
