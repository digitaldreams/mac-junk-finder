import Darwin
import Foundation
import JunkCore

// First call in the process: never let enumeration trigger iCloud/File Provider downloads.
setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)

let now = Date()
print(render(scan(root: FileManager.default.homeDirectoryForCurrentUser, now: now), now: now), terminator: "")
