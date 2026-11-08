import Foundation

/// Timing log to stderr, enabled with FOCAL_LOG=1. Times are ms since the process started,
/// so "window shown" lines give launch-to-window latency directly.
enum Log {
    static let enabled = ProcessInfo.processInfo.environment["FOCAL_LOG"] != nil

    static let processStart: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date() }
        let tv = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }()

    static func event(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let ms = Date().timeIntervalSince(processStart) * 1000
        FileHandle.standardError.write(Data(String(format: "[focal %7.1f ms] %@\n", ms, message()).utf8))
    }
}
