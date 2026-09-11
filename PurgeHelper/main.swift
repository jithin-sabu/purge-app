import Foundation

// The privileged helper is a launchd daemon: it runs as root, owns nothing on
// screen, and does one job — accept XPC connections from the genuine Purge app and
// move app bundles the user cannot remove unaided into the Trash. It stays alive on
// the main run loop; launchd starts it on demand for the Mach service and lets it
// idle-exit when no one is connected.
let delegate = HelperListenerDelegate()
let listener = NSXPCListener(machServiceName: PurgeHelperConstants.machServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
