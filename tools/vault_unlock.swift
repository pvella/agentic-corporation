import Foundation
import LocalAuthentication

/// Exit 0 = authenticated, 1 = failed/cancelled, 2 = unavailable.
let reason = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Unlock the Agentic Corporation office vault"

let context = LAContext()
var error: NSError?

// deviceOwnerAuthentication → Touch ID when enrolled, otherwise account password.
guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
    fputs("vault_unlock: LocalAuthentication unavailable: \(error?.localizedDescription ?? "unknown")\n", stderr)
    exit(2)
}

let sem = DispatchSemaphore(value: 0)
var ok = false
var failMsg = ""
context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, err in
    ok = success
    if let err = err {
        failMsg = err.localizedDescription
    }
    sem.signal()
}
_ = sem.wait(timeout: .now() + 120)
if ok {
    exit(0)
}
if !failMsg.isEmpty {
    fputs("vault_unlock: \(failMsg)\n", stderr)
}
exit(1)
