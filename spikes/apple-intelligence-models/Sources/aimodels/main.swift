import Foundation

let usage = """
aimodels: spike for removing the Apple Intelligence models and downloading them again later
(jithin-sabu/purge-app#133). Not part of Purge; nothing here is shipped.

  aimodels status                  what is installed, who uses it, the profile, free space
  aimodels measure [--dump] [--all] [--sets a,b]
                                   read MobileAsset's per-model records; --dump prints them raw
  aimodels check [--sets a,b] [--service id] [--urgency n] [--call-style sync|block]
                                   read-only: does this macOS still match the catalog, and does
                                   CacheDelete honour the service filter? Nothing is removed
  aimodels remove [--sets a,b] [--dry-run] [--yes] [--no-profile] [--no-purge]
                  [--service id] [--urgency n] [--amount bytes] [--call-style sync|block]
                                   block downloads, release, purge, measure the space freed
  aimodels restore [--sets a,b] [--yes]
                                   remove the block and ask macOS to download the models again
  aimodels snapshot [--note text]  record free space and the records to the journal
  aimodels selftest                checks that touch nothing on the system
  aimodels journal                 print the journal

Private calls run in a throwaway child process. The journal is at
~/Library/Application Support/Purge/spikes/apple-intelligence-models.json.

"""

let arguments = Array(CommandLine.arguments.dropFirst())

// The throwaway child: one private call, one JSON reply, exit.
if arguments.first == Worker.flag {
    guard arguments.count == 2 else { Log.fail("\(Worker.flag) needs an op") }
    Worker.serve(op: arguments[1])
}

let command = arguments.first
var rest = Arguments(Array(arguments.dropFirst()))

switch command {
case "status":
    rest.rejectUnknown()
    Commands.status()
case "measure":
    let dump = rest.flag("--dump")
    let all = rest.flag("--all")
    let sets = rest.option("--sets")
    rest.rejectUnknown()
    exit(Commands.measure(sets: sets, dump: dump, all: all) ? 0 : 1)
case "check":
    let options = Commands.PurgeOptions(from: &rest)
    let sets = rest.option("--sets")
    rest.rejectUnknown()
    exit(Commands.check(sets: sets, options: options) ? 0 : 1)
case "remove":
    let options = Commands.PurgeOptions(from: &rest)
    let sets = rest.option("--sets")
    let dryRun = rest.flag("--dry-run")
    let yes = rest.flag("--yes") || rest.flag("-y")
    let noProfile = rest.flag("--no-profile")
    let noPurge = rest.flag("--no-purge")
    rest.rejectUnknown()
    exit(Commands.remove(sets: sets, dryRun: dryRun, yes: yes, noProfile: noProfile, noPurge: noPurge, options: options) ? 0 : 1)
case "restore":
    let sets = rest.option("--sets")
    let yes = rest.flag("--yes") || rest.flag("-y")
    rest.rejectUnknown()
    exit(Commands.restore(sets: sets, yes: yes) ? 0 : 1)
case "snapshot":
    let note = rest.option("--note")
    rest.rejectUnknown()
    Commands.snapshot(note: note)
case "journal":
    rest.rejectUnknown()
    Log.line(Format.json(Journal.load()))
case "selftest":
    rest.rejectUnknown()
    exit(SelfTest.run() ? 0 : 1)
case "help", "--help", "-h", nil:
    print(usage, terminator: "")
default:
    print(usage, terminator: "")
    exit(1)
}
