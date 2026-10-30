import Testing
import Foundation
@testable import JunkCore

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

private func finding(_ path: String, size: Int64 = 1000) -> Finding {
    let kind: ItemKind = path.hasPrefix("Library/Logs") || path.hasPrefix("Downloads") ? .file : .dir
    let item = Item(path: path, kind: kind, size: size, modified: t0.addingTimeInterval(-400 * 86_400),
                    dateAdded: t0.addingTimeInterval(-400 * 86_400))
    return Finding(item: item, match: classify(item, now: t0)
        ?? Match(category: .cachesAndLogs, tier: .junk, ruleID: "C1", reason: "test"))
}

private func resultOf(_ paths: [String]) -> ScanResult {
    ScanResult(findings: paths.map { finding($0) })
}

private let allPaths = [
    "Library/Caches/com.foo.app", "Library/Caches/JetBrains", "Library/Logs/x.log",
    "Library/Developer/Xcode/DerivedData", "Library/Caches/Homebrew",
    "Downloads/a.pkg", "Downloads/b.dmg",
]

private func ids(_ fs: [Finding]) -> [String] { fs.map(\.item.path).sorted() }

// MARK: plan

@Suite struct CleanPlanTests {
    @Test func cachesSelectsOnlyC1() {
        let p = cleanPlan(resultOf(allPaths), sections: [.caches], runningBundleIDs: [])
        #expect(ids(p.remove) == ["Library/Caches/com.foo.app"])
    }
    @Test func logsSelectsOnlyC2() {
        let p = cleanPlan(resultOf(allPaths), sections: [.logs], runningBundleIDs: [])
        #expect(ids(p.remove) == ["Library/Logs/x.log"])
    }
    @Test func devSelectsD1AndD3() {
        let p = cleanPlan(resultOf(allPaths), sections: [.dev], runningBundleIDs: [])
        #expect(ids(p.remove) == ["Library/Caches/Homebrew", "Library/Developer/Xcode/DerivedData"])
    }
    @Test func installersSelectsJunkI1Only() {
        let p = cleanPlan(resultOf(allPaths), sections: [.installers], runningBundleIDs: [])
        #expect(ids(p.remove) == ["Downloads/a.pkg"])
    }
    @Test func reviewFindingsNeverSelected() {
        let p = cleanPlan(resultOf(allPaths), sections: [.caches, .logs, .dev, .installers], runningBundleIDs: [])
        #expect(p.remove.allSatisfy { $0.match.tier == .junk })
        #expect(!ids(p.remove).contains("Library/Caches/JetBrains"))
        #expect(!ids(p.remove).contains("Downloads/b.dmg"))
    }
    @Test func runningAppC1IsSkipped() {
        let p = cleanPlan(resultOf(allPaths), sections: [.caches], runningBundleIDs: ["com.foo.app"])
        #expect(p.remove.isEmpty)
        #expect(p.skipped.map(\.finding.item.path) == ["Library/Caches/com.foo.app"])
        #expect(p.skipped.first?.reason == "app running")
    }
    @Test func xcodeRunningSkipsD1KeepsD3() {
        let p = cleanPlan(resultOf(allPaths), sections: [.dev], runningBundleIDs: ["com.apple.dt.Xcode"])
        #expect(ids(p.remove) == ["Library/Caches/Homebrew"])
        #expect(p.skipped.map(\.finding.item.path) == ["Library/Developer/Xcode/DerivedData"])
    }
    @Test func unnamedSectionsUntouched() {
        let p = cleanPlan(resultOf(allPaths), sections: [], runningBundleIDs: [])
        #expect(p.remove.isEmpty && p.skipped.isEmpty)
    }
}

// MARK: arguments

@Suite struct CleanArgsTests {
    private func ok(_ a: [String]) -> CleanOptions? { if case .success(let o) = parseCleanArgs(a) { return o }; return nil }
    private func err(_ a: [String]) -> String? { if case .failure(let e) = parseCleanArgs(a) { return e.message }; return nil }

    @Test func noSectionIsUsage() { #expect(err([])?.contains("Usage") == true) }
    @Test func onlyFlagsIsUsage() { #expect(err(["--yes"])?.contains("Usage") == true) }
    @Test func unknownSectionIsUsage() { #expect(err(["nonsense"])?.contains("Usage") == true) }
    @Test func unknownFlagIsUsage() { #expect(err(["caches", "--force"])?.contains("Usage") == true) }
    @Test func bigIsRefused() {
        #expect(err(["big"]) == "Big files are Review only; delete them by hand")
        #expect(err(["caches", "big"]) == "Big files are Review only; delete them by hand")
    }
    @Test func flagsInAnyOrder() {
        let a = ok(["--yes", "caches", "--permanent", "logs"])
        let b = ok(["caches", "logs", "--permanent", "--yes"])
        #expect(a?.sections == [.caches, .logs] && a?.yes == true && a?.permanent == true)
        #expect(a == b)
    }
    @Test func defaultsAreNoYesTrash() {
        let o = ok(["dev"])
        #expect(o?.yes == false && o?.permanent == false && o?.sections == [.dev])
    }
    @Test func yesOnly() { #expect(ok(["dev", "--yes"])?.permanent == false) }
    @Test func permanentOnly() { #expect(ok(["--permanent", "dev"])?.yes == false) }
    @Test func duplicateSectionsCollapse() { #expect(ok(["dev", "dev"])?.sections == [.dev]) }
}

// MARK: fixtures

private struct Fixture { let base: URL; let root: URL; let outside: URL }

private func withFixture(_ body: (Fixture) throws -> Void) throws {
    let fm = FileManager.default
    let base = fm.homeDirectoryForCurrentUser.appendingPathComponent(".junkfinder-clean-test-\(UUID().uuidString)")
    let fx = Fixture(base: base, root: base.appendingPathComponent("home"), outside: base.appendingPathComponent("outside"))
    try fm.createDirectory(at: fx.root, withIntermediateDirectories: true)
    try fm.createDirectory(at: fx.outside, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    try body(Fixture(base: base, root: fx.root.resolvingSymlinksInPath(), outside: fx.outside.resolvingSymlinksInPath()))
}

private func mkdir(_ u: URL) throws { try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true) }
private func touch(_ u: URL) throws { try Data("x".utf8).write(to: u) }
private func exists(_ u: URL) -> Bool { (try? u.checkResourceIsReachable()) == true || (try? FileManager.default.destinationOfSymbolicLink(atPath: u.path)) != nil }

// MARK: re-checks

@Suite struct RecheckTests {
    @Test func intactItemPasses() throws {
        try withFixture { fx in
            try mkdir(fx.root.appendingPathComponent("Library/Caches/com.a"))
            #expect(recheck(finding("Library/Caches/com.a"), root: fx.root) == nil)
        }
    }
    @Test func deletedItemIsReported() throws {
        try withFixture { fx in
            try mkdir(fx.root.appendingPathComponent("Library/Caches"))
            #expect(recheck(finding("Library/Caches/gone"), root: fx.root) != nil)
        }
    }
    @Test func itemReplacedBySymlinkFails() throws {
        try withFixture { fx in
            try mkdir(fx.root.appendingPathComponent("Library/Caches"))
            try FileManager.default.createSymbolicLink(at: fx.root.appendingPathComponent("Library/Caches/com.a"),
                                                       withDestinationURL: fx.outside)
            #expect(recheck(finding("Library/Caches/com.a"), root: fx.root) != nil)
        }
    }
    @Test func parentSwappedForSymlinkFails() throws {
        try withFixture { fx in
            try mkdir(fx.outside.appendingPathComponent("com.a"))
            try mkdir(fx.root.appendingPathComponent("Library"))
            try FileManager.default.createSymbolicLink(at: fx.root.appendingPathComponent("Library/Caches"),
                                                       withDestinationURL: fx.outside)
            #expect(recheck(finding("Library/Caches/com.a"), root: fx.root) != nil)
        }
    }
    @Test func dotDotPathFails() throws {
        try withFixture { fx in
            try mkdir(fx.root.appendingPathComponent("Library/Caches"))
            try mkdir(fx.outside.appendingPathComponent("x"))
            #expect(recheck(finding("Library/Caches/../../../outside/x"), root: fx.root) != nil)
        }
    }
    @Test func emptyPathFails() throws {
        try withFixture { fx in
            #expect(recheck(finding("x"), root: fx.root) != nil)  // missing
            var f = finding("x"); f.item.path = ""
            #expect(recheck(f, root: fx.root) != nil)
        }
    }
}

// MARK: removal

@Suite struct RemovalTests {
    @Test func permanentRemovesFixtures() throws {
        try withFixture { fx in
            let a = fx.root.appendingPathComponent("Library/Caches/com.a")
            try mkdir(a); try touch(a.appendingPathComponent("f"))
            let b = fx.root.appendingPathComponent("Library/Caches/Homebrew")
            try mkdir(b)
            let out = performClean([finding("Library/Caches/com.a"), finding("Library/Caches/Homebrew")],
                                   root: fx.root, permanent: true)
            #expect(out.removed.count == 2 && out.failed.isEmpty && out.skipped.isEmpty)
            #expect(!exists(a) && !exists(b))
        }
    }
    @Test func swappedItemNotRemovedAndOutsideUntouched() throws {
        try withFixture { fx in
            try mkdir(fx.outside.appendingPathComponent("com.a"))
            try touch(fx.outside.appendingPathComponent("com.a/keep"))
            try mkdir(fx.root.appendingPathComponent("Library"))
            try FileManager.default.createSymbolicLink(at: fx.root.appendingPathComponent("Library/Caches"),
                                                       withDestinationURL: fx.outside)
            let out = performClean([finding("Library/Caches/com.a")], root: fx.root, permanent: true)
            #expect(out.removed.isEmpty && out.skipped.count == 1)
            #expect(exists(fx.outside.appendingPathComponent("com.a/keep")))
        }
    }
    @Test func symlinkedItemNotRemoved() throws {
        try withFixture { fx in
            try touch(fx.outside.appendingPathComponent("keep"))
            try mkdir(fx.root.appendingPathComponent("Library/Caches"))
            let link = fx.root.appendingPathComponent("Library/Caches/com.a")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fx.outside)
            let out = performClean([finding("Library/Caches/com.a")], root: fx.root, permanent: true)
            #expect(out.removed.isEmpty && out.skipped.count == 1)
            #expect(exists(fx.outside.appendingPathComponent("keep")) && exists(link))
        }
    }
    @Test func deletedBeforeRemovalIsSkippedNoCrash() throws {
        try withFixture { fx in
            try mkdir(fx.root.appendingPathComponent("Library/Caches"))
            let out = performClean([finding("Library/Caches/gone")], root: fx.root, permanent: true)
            #expect(out.skipped.count == 1 && out.removed.isEmpty && out.failed.isEmpty)
        }
    }
    @Test func trashMovesFixtureAndLeavesNothingInRealTrash() throws {
        try withFixture { fx in
            let a = fx.root.appendingPathComponent("Library/Caches/com.tiny")
            try mkdir(a); try touch(a.appendingPathComponent("f"))
            let out = performClean([finding("Library/Caches/com.tiny")], root: fx.root, permanent: false)
            defer { for u in out.trashedURLs { try? FileManager.default.removeItem(at: u) } }  // test cleanup only
            #expect(out.removed.count == 1 && out.failed.isEmpty)
            #expect(!exists(a))
            #expect(out.trashedURLs.count == 1 && exists(out.trashedURLs[0]))
        }
    }
}

// MARK: text

@Suite struct CleanTextTests {
    @Test func promptTrashAndPermanent() {
        #expect(cleanPrompt(count: 3, bytes: 1_200_000_000, permanent: false) == "Move 3 items (1.2 GB) to Trash? [y/N] ")
        #expect(cleanPrompt(count: 1, bytes: 5000, permanent: true)
                == "Permanently delete 1 items (5.0 KB)? This cannot be undone. [y/N] ".replacingOccurrences(of: "5.0 KB", with: "5 KB"))
    }
    @Test func confirmAcceptsOnlyYAndYes() {
        #expect(isConfirmed("y") && isConfirmed("YES") && isConfirmed(" yes "))
        #expect(!isConfirmed("") && !isConfirmed("n") && !isConfirmed("yep") && !isConfirmed(nil))
    }
    @Test func summaryTrash() {
        let o = CleanOutcome(removed: [finding("a", size: 2000)], skipped: [], failed: [], trashedURLs: [])
        let s = cleanSummary(o, extraSkipped: 1, permanent: false)
        #expect(s == "Moved 1 items (2 KB) to Trash; 1 skipped; 0 failed.\nSpace is freed when you empty the Trash.")
    }
    @Test func summaryPermanent() {
        #expect(cleanSummary(CleanOutcome(), extraSkipped: 0, permanent: true) == "Deleted 0 items (0 B); 0 skipped; 0 failed.")
    }
    @Test func exitCode() {
        #expect(cleanExitCode(CleanOutcome()) == 0)
        #expect(cleanExitCode(CleanOutcome(failed: [(finding("a"), "x")])) == 1)
    }
    @Test func planTextSanitisesPaths() {
        let f = finding("Library/Caches/a\nb\u{1B}[1A")
        let t = renderCleanPlan(remove: [f], skipped: [(f, "app running")])
        #expect(!t.contains("\u{1B}") && t.split(separator: "\n").count == 5)
    }
}
