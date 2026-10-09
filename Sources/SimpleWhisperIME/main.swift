import AppKit
import InputMethodKit

let connectionName = Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String ?? "pl.wojas.inputmethod.SimpleWhisper_Connection"
let server = IMKServer(name: connectionName, bundleIdentifier: Bundle.main.bundleIdentifier)
IMEBridge.shared.start()
NSApplication.shared.run()
