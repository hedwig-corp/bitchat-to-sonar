// QA-187 (iOS leg). Stand-in for the notification extension's store-lock
// behaviour, driven by scripts/qa/ios-launch-store-yield.sh against the REAL app
// on a simulator. `simctl push` never runs the real extension there.
//   nse_standin <lockfile> yield     -> hold the flock; release when the app
//                                       posts the host-wants notification
//   nse_standin <lockfile> stubborn  -> hold the flock for 13 s regardless
//                                       (the old extension: 5 s quorum + 8 s drain)
// Prints one line per event with a monotonic ms timestamp.
import Darwin
import Foundation
import notify

let args = CommandLine.arguments
guard args.count == 3 else { print("usage"); exit(2) }
let path = args[1], mode = args[2]
let t0 = DispatchTime.now().uptimeNanoseconds
func say(_ s: String) { print("\((DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)ms \(s)"); fflush(stdout) }

let fd = open(path, O_CREAT | O_WRONLY, 0o644)
guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { say("could not take the lock errno=\(errno)"); exit(3) }
say("holding store lock (\(mode))")
let done = DispatchSemaphore(value: 0)
var token: Int32 = NOTIFY_TOKEN_INVALID
let st = notify_register_dispatch("sh.hedwig.sonar.marmot.store.host-wants", &token, .global()) { _ in
    say("host-wants notification received")
    if mode == "yield" { flock(fd, LOCK_UN); say("released (yielded)"); done.signal() }
}
say("notify register status=\(st)")
if done.wait(timeout: .now() + 13) == .timedOut {
    flock(fd, LOCK_UN); say("released after 13 s hold")
}
close(fd)
