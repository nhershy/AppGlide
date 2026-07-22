//
//  AppLog.swift
//  AppGlide
//

import Foundation

/// Logs to both NSLog and ~/Library/Logs/AppGlide.log. The file exists
/// because unified logging proved unreadable for this process during
/// debugging — `log show` returned zero entries — so the file is the
/// dependable channel.
enum AppLog {
    private nonisolated static let fileURL = URL(
        fileURLWithPath: NSHomeDirectory() + "/Library/Logs/AppGlide.log"
    )

    nonisolated static func log(_ message: String) {
        NSLog("AppGlide: %@", message)
        let formatter = ISO8601DateFormatter()
        let line = "\(formatter.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }
}
