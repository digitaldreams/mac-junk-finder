import Foundation
import Testing
@testable import JunkCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }
private let MB: Int64 = 1_000_000

private func item(_ path: String, _ kind: ItemKind = .dir, siblings: [String] = [], size: Int64 = 1000,
                  modified: Double = 0, added: Double? = nil) -> Item {
    Item(path: path, kind: kind, siblings: siblings, size: size, modified: ago(modified),
         dateAdded: added.map(ago))
}
private func rule(_ i: Item) -> String? { classify(i, now: now)?.ruleID }

// MARK: Deny
@Test(arguments: [
    "Library/Caches/CloudKit", "Library/Caches/CloudKitOld",
    "Library/Caches/com.apple.FontRegistry", "Library/Caches/com.apple.FontRegistry.x",
    "Library/Caches/com.apple.Spotlight", "Library/Caches/com.apple.spotlight.x",
    "Library/Caches/com.apple.bird", "Library/Caches/com.apple.CloudDocs.MobileDocumentsFileProvider",
    "Library/Caches/com.apple.finder", "Library/Caches/pypoetry",
    "Library/Caches/org.R-project.R", "Library/Caches/kitty",
])
func denyList(_ path: String) { #expect(classify(item(path), now: now) == nil) }

@Test func denyDoesNotCatchOthers() {
    #expect(rule(item("Library/Caches/com.apple.birdy")) == "C1")
    #expect(rule(item("Library/Caches/kitty2")) == "C1")
}

// MARK: D1 / D3
@Test(arguments: ["Library/Developer/Xcode/DerivedData", "Library/Developer/CoreSimulator/Caches"])
func d1(_ p: String) {
    let m = classify(item(p), now: now)
    #expect(m?.ruleID == "D1"); #expect(m?.tier == .junk); #expect(m?.category == .devJunk)
    #expect(m?.reason == "Xcode build cache; quit Xcode first")
}
@Test func d1Negative() { #expect(classify(item("Library/Developer/Xcode/Archives"), now: now) == nil) }

@Test(arguments: ["Library/Caches/Homebrew", "Library/Caches/Yarn", "Library/Caches/pip",
                  "Library/Caches/CocoaPods", "Library/Caches/composer", ".npm/_cacache", ".cargo/registry/cache"])
func d3(_ p: String) {
    let m = classify(item(p), now: now)
    #expect(m?.ruleID == "D3"); #expect(m?.tier == .junk); #expect(m?.category == .devJunk)
}
@Test func d3Negative() { #expect(classify(item(".npm/other"), now: now) == nil) }

// MARK: D4 / D5
@Test func d4Positive() {
    let m = classify(item("p/target", siblings: ["Cargo.toml", "src"]), now: now)
    #expect(m?.ruleID == "D4"); #expect(m?.tier == .review); #expect(m?.category == .devJunk)
}
@Test func d4BareTargetIsNil() { #expect(classify(item("p/target"), now: now) == nil) }
@Test func d4PomOnlyIsNil() { #expect(classify(item("p/target", siblings: ["pom.xml"]), now: now) == nil) }

@Test func d5NodeModules() {
    let m = classify(item("p/node_modules", siblings: ["package.json"]), now: now)
    #expect(m?.ruleID == "D5"); #expect(m?.tier == .review)
}
@Test func d5DotBuild() {
    #expect(rule(item("p/.build", siblings: ["Package.swift"])) == "D5")
}
@Test func d5Negatives() {
    #expect(classify(item("p/node_modules"), now: now) == nil)
    #expect(classify(item("p/.build", siblings: ["package.json"]), now: now) == nil)
}
@Test func d5NotUnderHiddenTopLevel() {
    #expect(classify(item(".npm/_npx/x/node_modules", siblings: ["package.json"]), now: now) == nil)
    #expect(classify(item(".windsurf/extensions/x/node_modules", siblings: ["package.json"]), now: now) == nil)
    #expect(classify(item(".hidden/p/.build", siblings: ["Package.swift"]), now: now) == nil)
    #expect(rule(item("src/.x/node_modules", siblings: ["package.json"])) == "D5")
}
@Test func d5StaleNodeModulesIsJunk() {
    // modified = newest file inside the folder (set by the scanner)
    let old = classify(item("p/node_modules", siblings: ["package.json", "package-lock.json"], modified: 31), now: now)
    #expect(old?.ruleID == "D5"); #expect(old?.tier == .junk)
    #expect(classify(item("p/node_modules", siblings: ["package.json", "package-lock.json"], modified: 29), now: now)?.tier == .review)
}
@Test(arguments: ["package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "bun.lock"])
func d5AnyLockFileMakesStaleJunk(_ lock: String) {
    #expect(classify(item("p/node_modules", siblings: ["package.json", lock], modified: 31), now: now)?.tier == .junk)
}
@Test func staleWithoutLockFileStaysReview() {
    // without a lock file, reinstalling may pull different versions
    #expect(classify(item("p/node_modules", siblings: ["package.json"], modified: 400), now: now)?.tier == .review)
    #expect(classify(item("p/vendor", siblings: ["composer.json"], modified: 400), now: now)?.tier == .review)
}
@Test func d5StaleDotBuildStaysReview() {
    #expect(classify(item("p/.build", siblings: ["Package.swift"], modified: 400), now: now)?.tier == .review)
}
@Test func d6ComposerVendor() {
    let old = classify(item("p/vendor", siblings: ["composer.json", "composer.lock"], modified: 31), now: now)
    #expect(old?.ruleID == "D6"); #expect(old?.tier == .junk); #expect(old?.category == .devJunk)
    #expect(classify(item("p/vendor", siblings: ["composer.json", "composer.lock"], modified: 29), now: now)?.tier == .review)
}
@Test func d6Negatives() {
    #expect(classify(item("p/vendor", modified: 400), now: now) == nil)
    #expect(classify(item("p/vendor", siblings: ["go.mod"], modified: 400), now: now) == nil)
    #expect(classify(item(".composer/vendor", siblings: ["composer.json"], modified: 400), now: now) == nil)
}
@Test func d5BeatsB1() {
    let m = classify(item("p/node_modules", siblings: ["package.json"], size: 2000 * MB), now: now)
    #expect(m?.ruleID == "D5")
}

// MARK: C1r / C1
@Test(arguments: ["Library/Caches/ms-playwright", "Library/Caches/ms-playwright-1", "Library/Caches/JetBrains",
                  "Library/Caches/com.jetbrains.toolbox"])
func c1r(_ p: String) {
    let m = classify(item(p), now: now)
    #expect(m?.ruleID == "C1r"); #expect(m?.tier == .review); #expect(m?.category == .cachesAndLogs)
    #expect(m?.reason == "large download/index; slow to rebuild")
}
@Test func c1Positive() {
    let m = classify(item("Library/Caches/com.example.app"), now: now)
    #expect(m?.ruleID == "C1"); #expect(m?.tier == .junk); #expect(m?.category == .cachesAndLogs)
    #expect(m?.reason == "app cache; quit the app before deleting")
}
@Test func c1NegativeNotDirectChild() {
    #expect(classify(item("Library/Caches/com.example.app/sub"), now: now) == nil)
    #expect(classify(item("Other/Caches/x"), now: now) == nil)
}
@Test func precedenceHomebrewAndJetBrains() {
    #expect(rule(item("Library/Caches/Homebrew")) == "D3")
    #expect(rule(item("Library/Caches/JetBrains")) == "C1r")
}

// MARK: C2
@Test func c2Boundary() {
    #expect(classify(item("Library/Logs/a.log", .file, modified: 6), now: now) == nil)
    let m = classify(item("Library/Logs/a.log", .file, modified: 8), now: now)
    #expect(m?.ruleID == "C2"); #expect(m?.tier == .junk); #expect(m?.category == .cachesAndLogs)
}
@Test func c2DiagnosticReportsNested() {
    #expect(rule(item("Library/Logs/DiagnosticReports/x.ips", .file, modified: 30)) == "C2")
}
@Test func c2NegativeDirAndOutside() {
    #expect(classify(item("Library/Logs/Sub", .dir, modified: 30), now: now) == nil)
    #expect(classify(item("Library/Other/a.log", .file, modified: 30), now: now) == nil)
}

// MARK: I1
@Test func i1Boundary() {
    #expect(classify(item("Downloads/a.pkg", .file, added: 29), now: now) == nil)
    let m = classify(item("Downloads/a.pkg", .file, added: 31), now: now)
    #expect(m?.ruleID == "I1"); #expect(m?.tier == .junk); #expect(m?.category == .oldInstallers)
}
@Test(arguments: ["a.dmg", "a.iso", "A.DMG"])
func i1DiskImagesAreReview(_ n: String) {
    let m = classify(item("Downloads/\(n)", .file, added: 40), now: now)
    #expect(m?.ruleID == "I1"); #expect(m?.tier == .review)
    #expect(m?.reason == "installer or disk image; make sure it isn't your only copy")
}
@Test(arguments: ["a.pkg", "a.mpkg", "a.xip"])
func i1PackagesStayJunk(_ n: String) {
    let m = classify(item("Downloads/\(n)", .file, added: 40), now: now)
    #expect(m?.tier == .junk); #expect(m?.reason == "installer added over 30 days ago")
}
@Test(arguments: ["a.dmg", "a.pkg", "a.mpkg", "a.iso", "a.xip", "A.DMG"])
func i1Extensions(_ n: String) { #expect(rule(item("Downloads/\(n)", .file, added: 40)) == "I1") }
@Test func i1Negatives() {
    #expect(classify(item("Downloads/a.zip", .file, added: 40), now: now) == nil)
    #expect(classify(item("Other/a.dmg", .file, added: 40), now: now) == nil)
    #expect(classify(item("Downloads/a/b/c/a.dmg", .file, added: 40), now: now) == nil)
}
@Test func i1Package() { #expect(rule(item("Downloads/a.pkg", .package, added: 40)) == "I1") }
@Test func i1FallsBackToModified() {
    #expect(rule(item("Downloads/a.dmg", .file, modified: 31, added: nil)) == "I1")
    #expect(classify(item("Downloads/a.dmg", .file, modified: 29, added: nil), now: now) == nil)
}
@Test func i1DepthTwo() { #expect(rule(item("Downloads/sub/a.dmg", .file, added: 40)) == "I1") }

// MARK: B1
@Test func b1Boundary() {
    #expect(classify(item("Movies/a.mov", .file, size: 499 * MB, modified: 200), now: now) == nil)
    let m = classify(item("Movies/a.mov", .file, size: 500 * MB, modified: 200), now: now)
    #expect(m?.ruleID == "B1"); #expect(m?.tier == .review); #expect(m?.category == .bigFiles)
}
@Test func b1AgeGate() {
    #expect(classify(item("Movies/a.mov", .file, size: 600 * MB, modified: 179), now: now) == nil)
    let m = classify(item("Movies/a.mov", .file, size: 600 * MB, modified: 181), now: now)
    #expect(m?.ruleID == "B1")
    #expect(m?.reason.contains("stale") == false)
}
@Test func b1Package() { #expect(rule(item("Applications/Foo.app", .package, size: 600 * MB, modified: 200)) == "B1") }
@Test func b1NotForDirs() { #expect(classify(item("Movies/dir", .dir, size: 600 * MB), now: now) == nil) }
@Test func b1AfterOtherRules() {
    // an old big dmg in Downloads is I1, not B1
    #expect(rule(item("Downloads/a.dmg", .file, size: 900 * MB, added: 40)) == "I1")
}
