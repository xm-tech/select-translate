import AppKit

let arguments = CommandLine.arguments
if let index = arguments.firstIndex(of: "--log"), index + 1 < arguments.count {
    Log.configure(path: arguments[index + 1])
} else {
    Log.configureDefault()
}
Log.info("launch args=\(arguments.dropFirst().joined(separator: " "))")

if arguments.contains("--selftest") {
    SelfTest.runTranslationCLI()
    exit(0)
}

if arguments.contains("--axtest") {
    SelfTest.runAccessibilityProbe()
    exit(0)
}

if arguments.contains("--appletest") {
    SelfTest.runAppleTranslationTest()
    exit(0)
}

if let index = arguments.firstIndex(of: "--icon"), index + 1 < arguments.count {
    let path = arguments[index + 1]
    let ok = SelfTest.renderAppIcon(to: path)
    print(ok ? "icon written: \(path)" : "icon failed")
    exit(ok ? 0 : 1)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
