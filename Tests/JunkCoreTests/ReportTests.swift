import Foundation
import Testing
@testable import JunkCore
import enum JunkCore.Category

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

private func finding(_ path: String, _ cat: Category, _ tier: Tier, rule: String = "X", size: Int64,
                     modified: Double = 10, added: Double? = nil, reason: String = "why") -> Finding {
    Finding(item: Item(path: path, kind: .file, size: size, modified: ago(modified), dateAdded: added.map(ago)),
            match: Match(category: cat, tier: tier, ruleID: rule, reason: reason))
}
private func lines(_ s: String) -> [String] { s.components(separatedBy: "\n") }
private func index(of needle: String, in s: String) -> Int? { lines(s).firstIndex { $0.contains(needle) } }

@Test(arguments: [
    (Int64(0), "0 B"), (999, "999 B"), (1_000, "1 KB"), (12_000, "12 KB"), (999_000, "999 KB"),
    (999_499, "999 KB"), (999_500, "1.0 MB"), (1_000_000, "1.0 MB"), (1_234_567, "1.2 MB"),
    (340_000_000, "340 MB"), (999_000_000, "999 MB"), (999_500_000, "1.0 GB"), (1_000_000_000, "1.0 GB"),
    (99_949_999, "99.9 MB"), (99_950_000, "100 MB"), (99_950_000_000, "100 GB"),
    (1_200_000_000, "1.2 GB"), (2_500_000_000_000, "2.5 TB"),
])
func sizeFormatting(_ bytes: Int64, _ expected: String) { #expect(formatSize(bytes) == expected) }

@Test func exactSmallReport() {
    let r = ScanResult(
        findings: [finding("Library/Caches/Big", .cachesAndLogs, .junk, rule: "C1", size: 340_000_000,
                           modified: 214, reason: "app cache")],
        skipped: [Skipped(path: ".Trash", kind: .protected)])
    let out = render(r, now: now)
    let expected = """
    Caches & logs
        340 MB  junk    ~/Library/Caches/Big  (modified 214 d ago)  C1: app cache

    Junk (reclaimable): 340 MB
    Review (check before deleting): 0 B

    Skipped (not counted, sizes incomplete): 1 protected by macOS privacy (~/.Trash)

    Notes
    - Sizes are allocated bytes (what the files occupy on disk), not logical sizes.
    - Hard links are counted once; clones are counted at full size, so real savings may be smaller.
    - Space held by local Time Machine snapshots is not freed until they expire (tmutil listlocalsnapshots /).
    - Finder and System Settings "Available" will not rise one-for-one; they use volume-level figures that will not match these totals.
    - Caches regenerate, and macOS purges many of them itself.
    - Skipped and built-in excluded areas are not scanned, so totals are a lower bound.
    - Not scanned by design: Trash, Mail, cloud folders, app containers, Application Support, Desktop, Documents, Pictures, Music.

    """
    #expect(out == expected)
}

@Test func sectionOrderAndSortingAndTotals() {
    let r = ScanResult(findings: [
        finding("big/a.bin", .bigFiles, .review, size: 700_000_000),
        finding("Downloads/x.dmg", .oldInstallers, .junk, size: 5_000_000),
        finding("p/target", .devJunk, .review, size: 1_000_000),
        finding("p2/DerivedData", .devJunk, .junk, size: 9_000_000),
        finding("Library/Caches/small", .cachesAndLogs, .junk, size: 1_000),
        finding("Library/Caches/large", .cachesAndLogs, .junk, size: 2_000),
    ], skipped: [])
    let out = render(r, now: now)
    let heads = ["Caches & logs", "Dev junk", "Old installers", "Big files"].map { index(of: $0, in: out)! }
    #expect(heads == heads.sorted())
    #expect(index(of: "~/Library/Caches/large", in: out)! < index(of: "~/Library/Caches/small", in: out)!)
    #expect(index(of: "~/p2/DerivedData", in: out)! < index(of: "~/p/target", in: out)!)
    #expect(out.contains("Junk (reclaimable): 14.0 MB"))   // 9,000,000 + 5,000,000 + 3,000
    #expect(out.contains("Review (check before deleting): 701 MB"))
}

@Test func emptyCategoriesOmitted() {
    let out = render(ScanResult(findings: [finding("a", .bigFiles, .review, size: 600_000_000)], skipped: []), now: now)
    #expect(!out.contains("Dev junk"))
    #expect(out.contains("Big files"))
}

@Test func installerUsesAddedAge() {
    let f = finding("Downloads/x.dmg", .oldInstallers, .junk, rule: "I1", size: 1_000_000, modified: 400, added: 95)
    #expect(render(ScanResult(findings: [f], skipped: []), now: now).contains("added 95 d ago"))
}

@Test func installerFallsBackToModified() {
    let f = finding("Downloads/x.dmg", .oldInstallers, .junk, rule: "I1", size: 1_000_000, modified: 40)
    #expect(render(ScanResult(findings: [f], skipped: []), now: now).contains("modified 40 d ago"))
}

@Test func noFindings() {
    let out = render(ScanResult(findings: [], skipped: []), now: now)
    #expect(out.contains("No junk found."))
    #expect(out.contains("Skipped: none"))
    #expect(out.contains("Junk (reclaimable): 0 B"))
}

@Test func skippedLineCoversEveryKindAndNeverShowsSize() {
    let r = ScanResult(findings: [], skipped: [
        Skipped(path: ".Trash", kind: .protected), Skipped(path: "Library/Mail", kind: .protected),
        Skipped(path: "locked", kind: .owner), Skipped(path: "iCloudOnly", kind: .cloudOnly),
        Skipped(path: "Volumes/x", kind: .mountPoint), Skipped(path: "weird", kind: .other),
    ])
    let line = lines(render(r, now: now)).first { $0.hasPrefix("Skipped") }!
    #expect(line.contains("2 protected by macOS privacy (~/.Trash, ~/Library/Mail)"))
    #expect(line.contains("1 no permission (~/locked)"))
    #expect(line.contains("1 cloud-only (~/iCloudOnly)"))
    #expect(line.contains("1 other volume (~/Volumes/x)"))
    #expect(line.contains("1 unreadable, unknown error (~/weird)"))
    #expect(!line.contains(" B"))
}

@Test func skippedNamesAreTruncated() {
    let s = (1...5).map { Skipped(path: "p\($0)", kind: .protected) }
    let line = lines(render(ScanResult(findings: [], skipped: s), now: now)).first { $0.hasPrefix("Skipped") }!
    #expect(line.contains("5 protected by macOS privacy (~/p1, ~/p2, ~/p3, ...)"))
}

@Test func controlCharactersInPathsAreReplaced() {
    let hostile = "evil\n\u{1B}[1Adir\u{7F}x"
    let r = ScanResult(findings: [finding(hostile, .bigFiles, .review, size: 600_000_000)],
                       skipped: [Skipped(path: hostile, kind: .protected)])
    let out = render(r, now: now)
    #expect(!out.contains("\u{1B}"))
    #expect(!out.contains("\u{7F}"))
    #expect(out.contains("~/evil??[1Adir?x"))
    #expect(lines(out).filter { $0.contains("evil") }.count == 2)   // one finding row, one skipped line
}
