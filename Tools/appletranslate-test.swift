import AppKit
import Translation

let en = Locale.Language(identifier: "en")
let zh = Locale.Language(identifier: "zh-Hans")

func log(_ s: String) {
    FileHandle.standardError.write(("[" + String(format: "%.1f", Date().timeIntervalSince(start)) + "s] " + s + "\n").data(using: .utf8)!)
}

let start = Date()

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

DispatchQueue.global().async {
    let sem = DispatchSemaphore(value: 0)
    Task {
        let availability = LanguageAvailability()
        let status = await availability.status(from: en, to: zh)
        log("status en->zh = \(status)")

        let supported = await availability.supportedLanguages
        log("supportedLanguages count=\(supported.count)")
        if !supported.isEmpty {
            log("zh support = \(supported.contains { $0.languageCode?.identifier == "zh" })")
        }

        guard status == .installed else {
            log("language pack not installed; nothing to translate")
            sem.signal()
            return
        }
        do {
            let session = TranslationSession(installedSource: en, target: zh)
            let t0 = Date()
            let response = try await session.translate("The meeting has been moved to Thursday afternoon, please update the shared calendar.")
            log("translated in \(String(format: "%.0f", Date().timeIntervalSince(t0) * 1000))ms: \(response.targetText)")
            let short = try await session.translate("Hello world.")
            log("short: \(short.targetText)")
        } catch {
            log("error: \(error)")
        }
        sem.signal()
    }
    sem.wait()
    exit(0)
}

DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
    log("TIMEOUT")
    exit(2)
}

app.run()
