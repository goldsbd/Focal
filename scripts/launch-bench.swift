// Time from `open -a APP FILE` until APP has a new on-screen window, measured from outside the app
// (window server), plus that window's frame. Usage: swift scripts/launch-bench.swift APP FILE OWNERNAME
import AppKit

let args = CommandLine.arguments
let (app, file, owner) = (args[1], args[2], args[3])

func windows() -> [[String: Any]] {
    (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
        .filter { ($0[kCGWindowOwnerName as String] as? String) == owner && ($0[kCGWindowLayer as String] as? Int) == 0 }
}

let before = Set(windows().compactMap { $0[kCGWindowNumber as String] as? Int })
let start = Date()
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
p.arguments = ["-a", app, file]
try p.run()
while Date().timeIntervalSince(start) < 10 {
    if let w = windows().first(where: { !before.contains($0[kCGWindowNumber as String] as? Int ?? -1) }),
       let b = w[kCGWindowBounds as String] as? [String: CGFloat] {
        print(String(format: "%.0f ms  window x=%.0f y=%.0f w=%.0f h=%.0f", Date().timeIntervalSince(start) * 1000,
                     b["X"]!, b["Y"]!, b["Width"]!, b["Height"]!))
        exit(0)
    }
    usleep(2000)
}
print("timeout")
