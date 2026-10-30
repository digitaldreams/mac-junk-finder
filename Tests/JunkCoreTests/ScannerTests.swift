import Testing
import Foundation
@testable import JunkCore

// MARK: error classifier

@Suite struct ErrorClassifierTests {
    private func cocoa257(underlying code: Int32?) -> NSError {
        var info: [String: Any] = [:]
        if let code { info[NSUnderlyingErrorKey] = NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
        return NSError(domain: NSCocoaErrorDomain, code: 257, userInfo: info)
    }

    @Test func cocoa257WithEPERMIsProtected() {
        #expect(classifyScanError(cocoa257(underlying: EPERM)) == .protected)
    }
    @Test func posixEPERMIsProtected() {
        #expect(classifyScanError(NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))) == .protected)
    }
    @Test func cocoa257WithEACCESIsOwner() {
        #expect(classifyScanError(cocoa257(underlying: EACCES)) == .owner)
    }
    @Test func posixEACCESIsOwner() {
        #expect(classifyScanError(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))) == .owner)
    }
    @Test func posixEDEADLKIsCloudOnly() {
        #expect(classifyScanError(NSError(domain: NSPOSIXErrorDomain, code: Int(EDEADLK))) == .cloudOnly)
    }
    @Test func cocoa257WithEDEADLKIsCloudOnly() {
        #expect(classifyScanError(cocoa257(underlying: EDEADLK)) == .cloudOnly)
    }
    @Test func unknownIsOther() {
        #expect(classifyScanError(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))) == .other)
    }
}

// MARK: fixtures

private struct Fixture {
    let base: URL
    let root: URL      // stands in for ~
    let outside: URL   // a sibling tree the scan must never reach through links
}

private func withFixture(_ body: (Fixture) throws -> Void) throws {
    let fm = FileManager.default
    let base = fm.homeDirectoryForCurrentUser.appendingPathComponent(".junkfinder-test-\(UUID().uuidString)")
    let fx = Fixture(base: base, root: base.appendingPathComponent("home"), outside: base.appendingPathComponent("outside"))
    try fm.createDirectory(at: fx.root, withIntermediateDirectories: true)
    try fm.createDirectory(at: fx.outside, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    try body(fx)
}

private func mkdir(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
}

/// Writes real (non-sparse) bytes so allocated size is about `megabytes`.
private func write(_ url: URL, megabytes: Int) throws {
    try mkdir(url.deletingLastPathComponent())
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let h = try FileHandle(forWritingTo: url)
    defer { try? h.close() }
    let chunk = Data(repeating: 0x41, count: 1_048_576)
    for _ in 0..<megabytes { try h.write(contentsOf: chunk) }
}

private func touch(_ url: URL) throws {
    try mkdir(url.deletingLastPathComponent())
    FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
}

@Suite struct ScannerTests {
    let now = Date()

    @Test func hardLinkPairCountedOnce() throws {
        try withFixture { fx in
            let dir = fx.root.appendingPathComponent("Library/Caches/app")
            try write(dir.appendingPathComponent("a.bin"), megabytes: 1)
            try FileManager.default.linkItem(at: dir.appendingPathComponent("a.bin"), to: dir.appendingPathComponent("b.bin"))
            let r = scan(root: fx.root, now: now)
            #expect(r.findings.count == 1)
            #expect(r.findings.first?.match.ruleID == "C1")
            let size = r.findings.first?.item.size ?? 0
            #expect(size >= 1_000_000 && size < 1_600_000)
        }
    }

    @Test func sparseFileSizedByAllocation() throws {
        try withFixture { fx in
            let dir = fx.root.appendingPathComponent("Library/Caches/sp")
            try mkdir(dir)
            let url = dir.appendingPathComponent("s.bin")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let h = try FileHandle(forWritingTo: url)
            try h.seek(toOffset: 99 * 1_048_576)
            try h.write(contentsOf: Data(repeating: 0x41, count: 1_048_576))
            try h.close()
            let r = scan(root: fx.root, now: now)
            let size = r.findings.first?.item.size ?? 0
            #expect(size >= 1_000_000 && size < 2_000_000)
        }
    }

    @Test func symlinksAreNotFollowedAndLoopsEnd() throws {
        try withFixture { fx in
            try touch(fx.outside.appendingPathComponent("Library/Caches/x/f.txt"))
            let fm = FileManager.default
            try fm.createSymbolicLink(at: fx.root.appendingPathComponent("Library"),
                                      withDestinationURL: fx.outside.appendingPathComponent("Library"))
            try fm.createSymbolicLink(at: fx.root.appendingPathComponent("loop"), withDestinationURL: fx.root)
            let r = scan(root: fx.root, now: now)
            #expect(r.findings.isEmpty)
        }
    }

    @Test func unreadableDirRecordedAsOwnerAndScanContinues() throws {
        try withFixture { fx in
            let locked = fx.root.appendingPathComponent("locked")
            try touch(locked.appendingPathComponent("inner.txt"))
            try touch(fx.root.appendingPathComponent("Library/Caches/app/f.txt"))
            chmod(locked.path, 0o000)
            defer { chmod(locked.path, 0o755) }
            let r = scan(root: fx.root, now: now)
            #expect(r.skipped == [Skipped(path: "locked", kind: .owner)])
            #expect(r.findings.map(\.item.path) == ["Library/Caches/app"])
        }
    }

    @Test func nestedNodeModulesIsOneFindingCountedOnce() throws {
        try withFixture { fx in
            let proj = fx.root.appendingPathComponent("proj")
            try touch(proj.appendingPathComponent("package.json"))
            try write(proj.appendingPathComponent("node_modules/p/a.bin"), megabytes: 1)
            try touch(proj.appendingPathComponent("node_modules/a/node_modules/b/package.json"))
            try write(proj.appendingPathComponent("node_modules/a/node_modules/b/b.bin"), megabytes: 1)
            let r = scan(root: fx.root, now: now)
            #expect(r.findings.count == 1)
            #expect(r.findings.first?.item.path == "proj/node_modules")
            let size = r.findings.first?.item.size ?? 0
            #expect(size >= 2_000_000 && size < 2_400_000)
        }
    }

    @Test func appBundleIsOneB1FindingWithoutInnerFile() throws {
        try withFixture { fx in
            let big = fx.root.appendingPathComponent("Foo.app/Contents/big.bin")
            try write(big, megabytes: 600)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-200 * 86_400)], ofItemAtPath: big.path)
            let r = scan(root: fx.root, now: now)
            #expect(r.findings.map(\.item.path) == ["Foo.app"])
            #expect(r.findings.first?.match.ruleID == "B1")
            #expect(r.findings.first?.item.kind == .package)
        }
    }

    @Test func skipListDirYieldsNothing() throws {
        try withFixture { fx in
            let docs = fx.root.appendingPathComponent("Documents/proj")
            try touch(docs.appendingPathComponent("package.json"))
            try touch(docs.appendingPathComponent("node_modules/x.js"))
            try touch(fx.root.appendingPathComponent("Library/Containers/c/Library/Caches/y/f.txt"))
            try touch(fx.root.appendingPathComponent(".cargo/bin/Library/Caches/z/f.txt"))
            let r = scan(root: fx.root, now: now)
            #expect(r.findings.isEmpty)
        }
    }

    @Test func symlinkedDmgInDownloadsIsIgnored() throws {
        try withFixture { fx in
            let fm = FileManager.default
            let real = fx.root.appendingPathComponent("Downloads/real.dmg")
            try touch(real)
            let target = fx.outside.appendingPathComponent("t.dmg")
            try touch(target)
            try fm.createSymbolicLink(at: fx.root.appendingPathComponent("Downloads/link.dmg"), withDestinationURL: target)
            let future = now.addingTimeInterval(100 * 86_400)
            let r = scan(root: fx.root, now: future)
            #expect(r.findings.map(\.item.path) == ["Downloads/real.dmg"])
            #expect(r.findings.first?.match.ruleID == "I1")
        }
    }

    @Test func nodeModulesWithBigFileIsD5Only() throws {
        try withFixture { fx in
            try touch(fx.root.appendingPathComponent("proj/package.json"))
            try write(fx.root.appendingPathComponent("proj/node_modules/big.bin"), megabytes: 600)
            let r = scan(root: fx.root, now: now)
            #expect(r.findings.map(\.match.ruleID) == ["D5"])
            #expect((r.findings.first?.item.size ?? 0) >= 600_000_000)
        }
    }

    private func setMtime(_ url: URL, daysAgo: Double) throws {
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-daysAgo * 86_400)], ofItemAtPath: url.path)
    }

    @Test func dirAgesFromNewestRegularFile() throws {
        try withFixture { fx in
            let dir = fx.root.appendingPathComponent("Library/Caches/app")
            try touch(dir.appendingPathComponent("old.txt"))
            try touch(dir.appendingPathComponent("sub/new.txt"))
            try setMtime(dir.appendingPathComponent("old.txt"), daysAgo: 300)
            try setMtime(dir.appendingPathComponent("sub/new.txt"), daysAgo: 2)
            try setMtime(dir.appendingPathComponent("sub"), daysAgo: 400)
            try setMtime(dir, daysAgo: 400)
            let r = scan(root: fx.root, now: now)
            let m = try #require(r.findings.first?.item.modified)
            #expect(abs(now.timeIntervalSince(m) - 2 * 86_400) < 5)
        }
    }

    @Test func emptyMatchedDirIsDropped() throws {
        try withFixture { fx in
            try mkdir(fx.root.appendingPathComponent("Library/Caches/Yarn"))
            try mkdir(fx.root.appendingPathComponent("Library/Caches/Empty/sub"))
            try touch(fx.root.appendingPathComponent("Library/Caches/full/f.txt"))
            let r = scan(root: fx.root, now: now)
            #expect(r.findings.map(\.item.path) == ["Library/Caches/full"])
        }
    }

    @Test func d5NotMatchedUnderHiddenTopLevel() throws {
        try withFixture { fx in
            try touch(fx.root.appendingPathComponent(".npm/_npx/x/package.json"))
            try touch(fx.root.appendingPathComponent(".npm/_npx/x/node_modules/f.js"))
            try touch(fx.root.appendingPathComponent("proj/package.json"))
            try touch(fx.root.appendingPathComponent("proj/node_modules/f.js"))
            let r = scan(root: fx.root, now: now)
            #expect(r.findings.map(\.item.path) == ["proj/node_modules"])
        }
    }

    @Test func composerVendorFound() throws {
        try withFixture { fx in
            try touch(fx.root.appendingPathComponent("proj/composer.json"))
            try touch(fx.root.appendingPathComponent("proj/vendor/autoload.php"))
            let r = scan(root: fx.root, now: now)
            #expect(r.findings.map(\.match.ruleID) == ["D6"])
        }
    }
}
