import Foundation

/// 极简文件日志：菜单栏 App 没有终端，出问题时全靠这个文件排查。
enum Log {
    private static let queue = DispatchQueue(label: "com.maxion.selecttranslate.log")
    private static var fileURL: URL?

    static func configure(path: String?) {
        guard let path, !path.isEmpty else { return }
        fileURL = URL(fileURLWithPath: path)
        let dir = fileURL!.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    static func configureDefault() {
        guard fileURL == nil else { return }
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        fileURL = base.appendingPathComponent("SelectTranslate.log")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    static var path: String? { fileURL?.path }

    static func info(_ message: String) {
        queue.async {
            configureDefault()
            guard let url = fileURL else { return }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let line = "\(formatter.string(from: Date()))  \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
