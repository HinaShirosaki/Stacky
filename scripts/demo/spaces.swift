// spaces list | spaces move <pid> <desktop-number>   (moves every window of the process; setup helper for demos)
import AppKit
let sl = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)!
func sym<T>(_ n: String, _: T.Type) -> T { unsafeBitCast(dlsym(sl, n), to: T.self) }
let cid = sym("SLSMainConnectionID", (@convention(c) () -> Int32).self)()
let managed = sym("SLSCopyManagedDisplaySpaces", (@convention(c) (Int32) -> Unmanaged<CFArray>?).self)
let assign = sym("SLSProcessAssignToSpace", (@convention(c) (Int32, Int32, UInt64) -> Int32).self)
var desktops: [UInt64] = []
for d in managed(cid)?.takeRetainedValue() as? [[String: Any]] ?? [] {
    for s in d["Spaces"] as? [[String: Any]] ?? [] where (s["type"] as? Int) == 0 { desktops.append(s["ManagedSpaceID"] as! UInt64) }
}
let a = CommandLine.arguments
if a[1] == "list" { print(desktops) } else {
    let pid = Int32(a[2])!, space = desktops[Int(a[3])! - 1]
    print(assign(cid, pid, space), assign(cid, pid, 0))
}
