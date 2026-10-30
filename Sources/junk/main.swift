import AppKit
import Darwin
import Foundation
import JunkCore

// First call in the process: never let enumeration trigger iCloud/File Provider downloads.
setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let home = FileManager.default.homeDirectoryForCurrentUser
let now = Date()
let args = Array(CommandLine.arguments.dropFirst())

guard args.first == "clean" else {
    print(render(scan(root: home, now: now), now: now), terminator: "")
    exit(0)
}

let options: CleanOptions
switch parseCleanArgs(Array(args.dropFirst())) {
case .success(let o): options = o
case .failure(let e): fail(e.message, code: 2)
}
if !options.yes, isatty(STDIN_FILENO) == 0 { fail("Refusing to clean without a terminal to confirm on; pass --yes to skip the prompt.", code: 2) }

let result = scan(root: home, now: now)
let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
let plan = cleanPlan(result, sections: Set(options.sections), runningBundleIDs: running)
if plan.remove.isEmpty && plan.skipped.isEmpty { print("Nothing to clean."); exit(0) }
print(renderCleanPlan(remove: plan.remove, skipped: plan.skipped))
if plan.remove.isEmpty { exit(0) }

if !options.yes {
    print(cleanPrompt(count: plan.remove.count, bytes: plan.remove.reduce(0) { $0 + $1.item.size }, permanent: options.permanent), terminator: "")
    guard isConfirmed(readLine()) else { print("Aborted; nothing removed."); exit(0) }
}

let outcome = performClean(plan.remove, root: home.resolvingSymlinksInPath(), permanent: options.permanent)
for (f, why) in outcome.skipped { print("skipped ~/\(safe(f.item.path)): \(why)") }
for (f, why) in outcome.failed { print("failed ~/\(safe(f.item.path)): \(safe(why))") }
print(cleanSummary(outcome, extraSkipped: plan.skipped.count, permanent: options.permanent))
exit(cleanExitCode(outcome))
