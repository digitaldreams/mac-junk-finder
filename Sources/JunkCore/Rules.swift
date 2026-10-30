import Foundation

public enum ItemKind: Sendable, Equatable { case file, dir, package }
public enum Category: Sendable, Equatable { case cachesAndLogs, devJunk, oldInstallers, bigFiles }
public enum Tier: Sendable, Equatable { case junk, review }

public struct Item: Sendable {
    public var path: String          // relative to ~
    public var kind: ItemKind
    public var siblings: [String]    // names of entries next to it
    public var size: Int64           // allocated bytes
    public var modified: Date
    public var dateAdded: Date?

    public init(path: String, kind: ItemKind, siblings: [String] = [], size: Int64 = 0,
                modified: Date, dateAdded: Date? = nil) {
        self.path = path; self.kind = kind; self.siblings = siblings
        self.size = size; self.modified = modified; self.dateAdded = dateAdded
    }
}

public struct Match: Sendable, Equatable {
    public var category: Category
    public var tier: Tier
    public var ruleID: String
    public var reason: String
}

private let day: TimeInterval = 86_400
private let denyPrefixes = ["CloudKit", "com.apple.FontRegistry", "com.apple.Spotlight", "com.apple.spotlight",
                            "com.apple.CloudDocs"]
private let denyExact: Set<String> = ["com.apple.bird", "com.apple.finder", "pypoetry", "org.R-project.R", "kitty"]
private let d1Paths: Set<String> = ["Library/Developer/Xcode/DerivedData", "Library/Developer/CoreSimulator/Caches"]
private let d3Caches: Set<String> = ["Homebrew", "Yarn", "pip", "CocoaPods", "composer"]
private let d3Paths: Set<String> = [".npm/_cacache", ".cargo/registry/cache"]
private let c1rPrefixes = ["ms-playwright", "JetBrains", "com.jetbrains.toolbox"]
private let installerExts: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip"]
private let npmLocks: Set<String> = ["package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "bun.lock"]
private let bigBytes: Int64 = 500 * 1_000_000

// ponytail: first-match rule chain; fine for 9 rules, revisit if the rule count grows past ~20.
public func classify(_ item: Item, now: Date) -> Match? {
    let parts = item.path.split(separator: "/").map(String.init)
    guard let name = parts.last else { return nil }
    let inCaches = parts.count >= 3 && parts[0] == "Library" && parts[1] == "Caches"
    let cacheChild = inCaches ? parts[2] : nil
    let age = { (d: Date) in now.timeIntervalSince(d) }

    // Deny
    if let c = cacheChild, denyExact.contains(c) || denyPrefixes.contains(where: c.hasPrefix) { return nil }

    // D1, D3
    if d1Paths.contains(item.path) {
        return Match(category: .devJunk, tier: .junk, ruleID: "D1", reason: "Xcode build cache; quit Xcode first")
    }
    if (parts.count == 3 && cacheChild.map(d3Caches.contains) == true) || d3Paths.contains(item.path) {
        return Match(category: .devJunk, tier: .junk, ruleID: "D3", reason: "package manager download cache; re-downloaded on demand")
    }

    // D4, D5, D6
    if item.kind == .dir {
        // Hidden top-level folders (.npm/_npx, editor extensions) are tool internals, not projects.
        let hiddenTop = parts[0].hasPrefix(".")
        if name == "target", item.siblings.contains("Cargo.toml") {
            return Match(category: .devJunk, tier: .review, ruleID: "D4", reason: "Rust build output next to Cargo.toml; rebuilt by cargo")
        }
        // `modified` is the newest file inside (every npm/composer install rewrites a lock file there).
        // Without a lock file a reinstall may pull different versions, so those stay Review.
        let stale = age(item.modified) > 30 * day
        if !hiddenTop, name == "node_modules", item.siblings.contains("package.json") {
            return stale && item.siblings.contains(where: npmLocks.contains)
                ? Match(category: .devJunk, tier: .junk, ruleID: "D5", reason: "npm packages, unchanged for over 30 days; npm install restores them")
                : Match(category: .devJunk, tier: .review, ruleID: "D5", reason: "project build/dependency folder; restored by package manager")
        }
        if !hiddenTop, name == ".build", item.siblings.contains("Package.swift") {
            return Match(category: .devJunk, tier: .review, ruleID: "D5", reason: "project build/dependency folder; restored by package manager")
        }
        if !hiddenTop, name == "vendor", item.siblings.contains("composer.json") {
            let junk = stale && item.siblings.contains("composer.lock")
            return Match(category: .devJunk, tier: junk ? .junk : .review, ruleID: "D6",
                         reason: junk ?"Composer packages, unchanged for over 30 days; composer install restores them"
                                       : "Composer packages; composer install restores them")
        }
    }

    // C1r, C1
    if parts.count == 3, let c = cacheChild {
        if c1rPrefixes.contains(where: c.hasPrefix) {
            return Match(category: .cachesAndLogs, tier: .review, ruleID: "C1r", reason: "large download/index; slow to rebuild")
        }
        return Match(category: .cachesAndLogs, tier: .junk, ruleID: "C1", reason: "app cache; quit the app before deleting")
    }

    // C2
    if item.kind == .file, parts.count >= 3, parts[0] == "Library", parts[1] == "Logs", age(item.modified) > 7 * day {
        return Match(category: .cachesAndLogs, tier: .junk, ruleID: "C2", reason: "log or crash report older than 7 days")
    }

    // I1
    // ponytail: "depth <= 2" read as at most 2 levels below Downloads (Downloads/sub/x.dmg).
    if item.kind != .dir, parts[0] == "Downloads", parts.count <= 3,
       installerExts.contains((name as NSString).pathExtension.lowercased()),
       age(item.dateAdded ?? item.modified) > 30 * day {
        // .dmg/.iso may be a user's encrypted disk image, so Review.
        if ["dmg", "iso"].contains((name as NSString).pathExtension.lowercased()) {
            return Match(category: .oldInstallers, tier: .review, ruleID: "I1",
                         reason: "installer or disk image; make sure it isn't your only copy")
        }
        return Match(category: .oldInstallers, tier: .junk, ruleID: "I1", reason: "installer added over 30 days ago")
    }

    // B1
    if item.kind != .dir, item.size >= bigBytes, age(item.modified) > 180 * day {
        return Match(category: .bigFiles, tier: .review, ruleID: "B1", reason: "large file (500 MB or more), not modified in over 180 days")
    }
    return nil
}
