import Foundation

enum Commands {
    /// Knobs for the CacheDelete step, kept explicit because none of them is
    /// documented: the spike records which values this macOS answers.
    struct PurgeOptions {
        var service = CacheDeleteCheck.defaultService
        var urgency = CacheDeleteCheck.defaultUrgency
        var callStyle = "sync"
        var amount: Int64?

        init() {}

        init(from arguments: inout Arguments) {
            if let service = arguments.option("--service") { self.service = service }
            if let urgency = arguments.option("--urgency") {
                guard let value = Int(urgency), (0...5).contains(value) else { Log.fail("--urgency takes 0 to 5") }
                self.urgency = value
            }
            if let style = arguments.option("--call-style") {
                guard style == "sync" || style == "block" else { Log.fail("--call-style is sync or block") }
                callStyle = style
            }
            if let amount = arguments.option("--amount") {
                guard let value = Int64(amount), value > 0 else { Log.fail("--amount takes a positive byte count") }
                self.amount = value
            }
        }
    }

    static func header() {
        let route = MacOS.releasesThroughService
            ? "release through the asset service, block with a profile"
            : "release with Apple's own switch in System Settings"
        Log.line("aimodels spike  ·  \(MacOS.label)  ·  \(MacOS.architecture)  ·  \(route)")
        if MacOS.major < 15 { Log.warn("Apple Intelligence needs macOS 15 or later; this Mac has nothing to remove") }
        if MacOS.architecture != "arm64" { Log.warn("Apple Intelligence runs on Apple silicon only; results here are unlikely to mean anything") }
        Log.line()
    }

    // MARK: status

    static func status() {
        header()
        let reading = Descriptors.read()
        let measured = Descriptors.measure(Catalog.sets, reading: reading)
        printMeasurements(measured, reading: reading)
        Log.line()
        printAccounts()
        Log.line()
        printProfile()
        Log.line()
        Log.line("Free space on /: " + Format.bytes(Volume.freeBytes()))
        if let last = Journal.load().last, let date = last["date"] as? String, let command = last["command"] as? String {
            Log.line("Last journal entry: \(command) at \(date)")
        }
    }

    static func printMeasurements(_ measured: [SetMeasurement], reading: DescriptorReading) {
        Log.line("Models on disk, from \(Descriptors.root)")
        Log.line("  " + Format.pad("set", 46) + Format.pad("records", 9) + Format.pad("size", 12) + Format.pad("locks", 7) + "folder")
        var total: Int64 = 0
        var allKnown = true
        for item in measured {
            if let bytes = item.bytes { total += bytes } else { allKnown = false }
            Log.line("  " + Format.pad(item.set.name, 46) + Format.pad("\(item.records.count)", 9)
                     + Format.pad(Format.bytes(item.bytes), 12) + Format.pad("\(item.locks.count)", 7) + item.folder.rawValue)
        }
        Log.line("  " + Format.pad("total", 46) + Format.pad("", 9) + (allKnown ? Format.bytes(total) : "unknown (a set has no readable record)"))
        let keys = Set(measured.flatMap { $0.sizeKeys })
        if !keys.isEmpty { Log.line("  size keys used: " + keys.sorted().joined(separator: ", ")) }
        Log.line("  records read: \(reading.records.count), unreadable: \(reading.unreadable.count), lock entries: \(reading.lockEntries.count)")
        for error in reading.errors { Log.warn(error) }
        if reading.records.isEmpty && reading.errors.isEmpty {
            Log.warn("no records at all: either nothing is downloaded or the layout differs on this macOS (run measure --dump --all)")
        }
    }

    static func printAccounts() {
        let accounts = Accounts.all()
        Log.line("Accounts on this Mac (the models are shared by all of them)")
        if accounts.isEmpty { Log.warn("could not list accounts with dscl") }
        for account in accounts {
            Log.line("  " + Format.pad(account.name + (account.isCurrent ? " (you)" : ""), 28) + account.usage.rawValue)
        }
    }

    static func printProfile() {
        let blocks = Profile.installedBlocks()
        let foreign = Profile.foreignBlocks()
        if blocks.isEmpty {
            Log.line("Download block: no Purge profile installed")
        } else {
            Log.line("Download block: Purge profile installed, blocking " + blocks.joined(separator: ", "))
        }
        for (type, url) in foreign.sorted(by: { $0.key < $1.key }) {
            Log.warn("another profile already redirects \(type) to \(url); not Purge's to touch")
        }
    }

    // MARK: measure

    static func measure(sets: String?, dump: Bool, all: Bool) -> Bool {
        header()
        let selected: [ModelSet]
        do { selected = try Catalog.select(sets) } catch { Log.fail("\(error)") }
        let reading = Descriptors.read()
        let measured = Descriptors.measure(selected, reading: reading)
        printMeasurements(measured, reading: reading)
        if !reading.unreadable.isEmpty {
            Log.line()
            Log.line("Unreadable records")
            for record in reading.unreadable { Log.line("  \(record.fileName): \(record.unreadable ?? "")") }
        }
        if dump {
            Log.line()
            let wanted = Set(selected.map(\.assetType))
            let records = all ? reading.records : reading.records.filter { record in
                record.assetType.map { wanted.contains($0) } ?? false
            }
            Log.line("Raw records (\(records.count))")
            for record in records {
                Log.line("--- \(record.path)")
                Log.line("    type: \(record.assetType ?? "?")  specifier: \(record.assetSpecifier ?? "?")  version: \(record.assetVersion ?? "?")")
                if !record.sizes.isEmpty { Log.line("    sizes: " + Format.json(record.sizes, pretty: false)) }
                if !record.hints.isEmpty { Log.line("    hints: " + Format.json(record.hints, pretty: false)) }
                if let raw = record.raw { Log.line(Format.json(raw)) }
            }
            Log.line()
            Log.line("Lock entries (\(reading.lockEntries.count))")
            for entry in reading.lockEntries where all || wanted.contains(where: { entry.contains($0) }) {
                Log.line("  " + entry)
            }
        }
        Journal.record("measure", note: nil, fields: ["sets": measured.map(\.summary), "errors": reading.errors])
        return reading.errors.isEmpty
    }

    // MARK: check

    struct Preflight {
        var frameworkLoads = false
        /// Sets whose asset type on this macOS matches the catalog.
        var mapped: [ModelSet] = []
        var skipped: [(ModelSet, String)] = []
        var serviceBytes: [String: Int64] = [:]
        var handlerReached: Bool?
        var handlerDetail: String?
        var knownServices: [String: String] = [:]
        var serviceDefined = false
        var unfilteredReply: [String: Any]?
        var filteredReply: [String: Any]?
        var cacheDeleteProblem: String?
        var verdict: CacheDeleteCheck.Verdict?

        var purgeAllowed: Bool { verdict?.honoured == true }

        var summary: [String: Any] {
            var out: [String: Any] = [
                "frameworkLoads": frameworkLoads,
                "mapped": mapped.map(\.name),
                "skipped": skipped.map { "\($0.0.name): \($0.1)" },
                "serviceBytes": serviceBytes,
                "knownServices": knownServices,
                "serviceDefined": serviceDefined,
            ]
            if let handlerReached { out["handlerReached"] = handlerReached }
            if let handlerDetail { out["handlerDetail"] = handlerDetail }
            if let unfilteredReply { out["unfilteredReply"] = unfilteredReply }
            if let filteredReply { out["filteredReply"] = filteredReply }
            if let cacheDeleteProblem { out["cacheDeleteProblem"] = cacheDeleteProblem }
            if let verdict {
                out["filterHonoured"] = verdict.honoured
                out["filterReason"] = verdict.reason
            }
            return out
        }
    }

    /// Everything read-only that has to hold before a release or a purge.
    /// `checkService` covers the asset service, `checkPurge` CacheDelete.
    static func preflight(_ sets: [ModelSet], options: PurgeOptions, checkService: Bool, checkPurge: Bool) -> Preflight {
        var result = Preflight()
        if checkService {
            Log.line("Asset service")
            let load = Worker.run("uaf-load", timeout: 30)
            result.frameworkLoads = load.ok && (load.result["available"] as? Bool ?? false)
            if !result.frameworkLoads {
                Log.warn("UnifiedAssetFramework could not be loaded: " + load.problem)
            } else {
                for set in sets {
                    let mapping = Worker.run("uaf-asset-type", ["assetSet": set.name], timeout: 30)
                    let type = mapping.result["assetType"] as? String
                    if !mapping.ok {
                        result.skipped.append((set, "asset type query failed: " + mapping.problem))
                    } else if type == set.assetType {
                        result.mapped.append(set)
                    } else if let type {
                        result.skipped.append((set, "macOS maps it to \(type), not \(set.assetType)"))
                    } else {
                        result.skipped.append((set, "macOS does not know this set"))
                    }
                    let bytes = Worker.run("uaf-bytes", ["assetSet": set.name], timeout: 30)
                    if bytes.ok, let value = bytes.result["bytes"] as? NSNumber { result.serviceBytes[set.name] = value.int64Value }
                    let matches = result.mapped.contains { $0.name == set.name }
                    let state = matches ? "matches" : "SKIP"
                    Log.line("  " + Format.pad(set.name, 46) + Format.pad(state, 9)
                             + "service says " + Format.bytes(result.serviceBytes[set.name]))
                }
                for (set, reason) in result.skipped { Log.warn("\(set.name): \(reason)") }
                let check = Worker.run("uaf-check", timeout: 60)
                result.handlerReached = check.ok ? (check.result["reachedHandler"] as? Bool ?? false) : false
                result.handlerDetail = check.ok ? (check.result["detail"] as? String) : check.problem
                if result.handlerReached == true {
                    Log.line("  reset handler reached with a set that does not exist (nothing was removed)")
                } else {
                    Log.warn("could not confirm the reset handler: " + (result.handlerDetail ?? "no detail"))
                }
            }
            Log.line()
        }
        if checkPurge {
            Log.line("CacheDelete")
            result.knownServices = CacheDeleteCheck.knownServices()
            let ids = Set(result.knownServices.values)
            result.serviceDefined = ids.contains(options.service)
            if result.knownServices.isEmpty {
                Log.warn("no service definitions readable under \(CacheDeleteCheck.definitions)")
            } else if result.serviceDefined {
                Log.line("  \(options.service) is a defined service")
            } else {
                let similar = result.knownServices.filter { $0.value.lowercased().contains("mobileasset") || $0.key.lowercased().contains("mobileasset") }
                Log.warn("\(options.service) is not among the \(result.knownServices.count) defined services")
                for (file, id) in similar.sorted(by: { $0.key < $1.key }) { Log.line("    similar: \(file) → \(id)") }
                Log.line("    pass the right one with --service")
            }
            let timeout: Double = 60
            let unfiltered = Worker.run("cd-purgeable", [
                "info": CacheDeleteCheck.request(service: nil, urgency: options.urgency, amount: nil),
                "style": options.callStyle, "timeout": timeout,
            ], timeout: timeout)
            let filtered = Worker.run("cd-purgeable", [
                "info": CacheDeleteCheck.request(service: options.service, urgency: options.urgency, amount: nil),
                "style": options.callStyle, "timeout": timeout,
            ], timeout: timeout)
            result.unfilteredReply = unfiltered.result["reply"] as? [String: Any]
            result.filteredReply = filtered.result["reply"] as? [String: Any]
            if !unfiltered.ok {
                result.cacheDeleteProblem = "unfiltered purgeable query: " + unfiltered.problem
            } else if !filtered.ok {
                result.cacheDeleteProblem = "filtered purgeable query: " + filtered.problem
            }
            if let problem = result.cacheDeleteProblem {
                Log.warn(problem)
                if unfiltered.timedOut || filtered.timedOut {
                    Log.line("    the \(options.callStyle) call style gave no reply; try --call-style " + (options.callStyle == "sync" ? "block" : "sync"))
                }
            }
            if let unfilteredReply = result.unfilteredReply {
                Log.line("  purgeable, no filter (\(options.callStyle) call, urgency \(options.urgency)):")
                Log.line(indent(Format.json(unfilteredReply)))
            }
            if let filteredReply = result.filteredReply {
                Log.line("  purgeable, filtered to \(options.service):")
                Log.line(indent(Format.json(filteredReply)))
            }
            if let filteredReply = result.filteredReply, let unfilteredReply = result.unfilteredReply {
                let verdict = CacheDeleteCheck.judge(filtered: filteredReply, unfiltered: unfilteredReply,
                                                     service: options.service, otherServices: Array(ids))
                result.verdict = verdict
                Log.line((verdict.honoured ? "  filter honoured: " : "  filter NOT honoured, purge would be refused: ") + verdict.reason)
            } else {
                Log.line("  filter cannot be judged, purge would be refused")
            }
            Log.line()
        }
        return result
    }

    static func indent(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n")
    }

    static func check(sets: String?, options: PurgeOptions) -> Bool {
        header()
        let selected: [ModelSet]
        do { selected = try Catalog.select(sets) } catch { Log.fail("\(error)") }
        let result = preflight(selected, options: options, checkService: true, checkPurge: true)
        let chosen: [String: Any] = ["service": options.service, "urgency": options.urgency, "callStyle": options.callStyle]
        Journal.record("check", note: nil, fields: ["preflight": result.summary, "options": chosen])
        let serviceOK = !MacOS.releasesThroughService || (result.frameworkLoads && !result.mapped.isEmpty && result.handlerReached == true)
        Log.line(serviceOK ? "Release: ready" : "Release: not ready on this macOS")
        Log.line(result.purgeAllowed ? "Purge: the service filter is honoured" : "Purge: would be refused")
        return serviceOK && result.purgeAllowed
    }

    // MARK: remove

    static func remove(sets: String?, dryRun: Bool, yes: Bool, noProfile: Bool, noPurge: Bool, options: PurgeOptions) -> Bool {
        header()
        guard MacOS.major >= 15 else { return false }
        let selected: [ModelSet]
        do { selected = try Catalog.select(sets) } catch { Log.fail("\(error)") }
        let readingBefore = Descriptors.read()
        let before = Descriptors.measure(selected, reading: readingBefore)
        printMeasurements(before, reading: readingBefore)
        Log.line()
        printAccounts()
        let others = Accounts.all().filter { !$0.isCurrent && $0.usage != .optedOut }
        Log.line()
        printProfile()
        Log.line()
        Log.line("Removing these sets switches off:")
        for set in selected { Log.line("  \(set.title): " + set.consumers.joined(separator: ", ")) }
        Log.line()

        let viaService = MacOS.releasesThroughService
        let flight = preflight(selected, options: options, checkService: viaService, checkPurge: !noPurge)
        if viaService && (!flight.frameworkLoads || flight.mapped.isEmpty) {
            Log.error("this macOS does not match the catalog, so nothing is sent")
            return false
        }
        if viaService && flight.handlerReached != true {
            Log.error("the reset handler could not be confirmed, so nothing is sent")
            return false
        }
        let releasing = viaService ? flight.mapped : selected
        let blockTypes = Profile.blockedTypes(for: releasing)

        Log.line("Plan")
        if viaService && !noProfile { Log.line("  1. install a profile that blocks downloads of " + blockTypes.joined(separator: ", ")) }
        if viaService {
            Log.line("  2. ask the asset service to release " + releasing.map(\.name).joined(separator: ", ") + " (one request per set)")
        } else {
            Log.line("  2. open Apple Intelligence & Siri so you can turn Apple Intelligence off (Apple's own switch releases the models)")
        }
        if noPurge {
            Log.line("  3. skip the purge (--no-purge)")
        } else if flight.purgeAllowed {
            Log.line("  3. ask deleted to purge \(options.service) now, urgency \(options.urgency)")
        } else {
            Log.line("  3. the purge is refused: " + (flight.verdict?.reason ?? flight.cacheDeleteProblem ?? "the filter could not be judged"))
        }
        Log.line("  4. measure the volume's free space before and after, and record it")
        if !others.isEmpty {
            Log.warn("other accounts share these models: " + others.map { "\($0.name) (\($0.usage.rawValue))" }.joined(separator: "; "))
        }
        Log.line()
        if dryRun {
            Log.line("Dry run, nothing changed.")
            return true
        }
        if !yes {
            guard isatty(STDIN_FILENO) == 1 else { Log.fail("run it in a terminal, or add --yes") }
            guard Shell.ask("Go ahead?") else {
                Log.line("Nothing changed.")
                return true
            }
        }

        var record: [String: Any] = ["sets": releasing.map(\.name), "before": before.map(\.summary), "preflight": flight.summary]
        guard let freeBefore = Volume.freeBytes() else { Log.fail("could not read the volume's free space") }
        record["freeBefore"] = freeBefore
        Log.line("Free space before: " + Format.bytes(freeBefore))

        // 1. Block downloads first, so nothing comes back between release and purge.
        if viaService && !noProfile {
            let installed = Profile.installedBlocks()
            if blockTypes.allSatisfy({ installed.contains($0) }) {
                Log.line("Profile: already installed")
            } else {
                do { try Profile.present(blocking: blockTypes) } catch { Log.fail("could not write the profile: \(error)") }
                Log.line("Profile: written to \(Profile.file.path) and opened. In System Settings, double-click it and choose Install.")
                guard Shell.waitFor("waiting for the profile", minutes: 10, {
                    let now = Profile.installedBlocks()
                    return blockTypes.allSatisfy { now.contains($0) }
                }) else {
                    Log.error("the profile was not installed, so nothing was released")
                    record["profile"] = "not installed"
                    Journal.record("remove", note: "stopped at the profile", fields: record)
                    return false
                }
                Log.line("Profile: installed")
            }
            record["profile"] = blockTypes
        }

        // 2. Release.
        var released: [String] = []
        var releaseFailures: [String: String] = [:]
        if viaService {
            for set in releasing {
                let reset = Worker.run("uaf-reset", ["assetSets": [set.name]], timeout: 130)
                if reset.ok {
                    released.append(set.name)
                    Log.line("Release: \(set.name) accepted")
                } else {
                    releaseFailures[set.name] = reset.problem
                    Log.warn("Release: \(set.name) failed: " + reset.problem)
                }
            }
        } else {
            Shell.openSettings(Shell.siriPane)
            Log.line("Turn Apple Intelligence off in System Settings > Apple Intelligence & Siri, then press Return here.")
            _ = readLine()
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let usage = Accounts.usage(home: home)
            released = usage == .usesAppleIntelligence ? [] : releasing.map(\.name)
            if usage == .usesAppleIntelligence { Log.warn("your account still reads as using Apple Intelligence") }
        }
        record["released"] = released
        record["releaseFailures"] = releaseFailures

        // 3. Purge now, only through the filter the read-only check confirmed.
        if !noPurge {
            if flight.purgeAllowed, let verdict = flight.verdict {
                let measuredTotal = before.compactMap(\.bytes).reduce(0, +)
                let amount = options.amount ?? verdict.filteredAmount ?? (measuredTotal > 0 ? measuredTotal : nil)
                if let amount, amount > 0 {
                    let info = CacheDeleteCheck.request(service: options.service, urgency: options.urgency, amount: amount)
                    Log.line("Purge: asking for " + Format.bytes(amount) + " from \(options.service)")
                    let purge = Worker.run("cd-purge", ["info": info, "style": options.callStyle, "timeout": 300.0], timeout: 300)
                    if purge.ok {
                        Log.line("Purge: replied")
                        if let reply = purge.result["reply"] as? [String: Any] {
                            Log.line(indent(Format.json(reply)))
                            record["purgeReply"] = reply
                        }
                    } else {
                        Log.warn("Purge: " + purge.problem)
                        record["purgeProblem"] = purge.problem
                    }
                } else {
                    Log.warn("Purge: no amount to ask for (nothing measured and the filtered query gave none); pass --amount")
                    record["purgeProblem"] = "no amount"
                }
            } else {
                let reason = flight.verdict?.reason ?? flight.cacheDeleteProblem ?? "the filter could not be judged"
                Log.warn("Purge refused: " + reason)
                record["purgeProblem"] = "refused: " + reason
            }
        }

        // 4. What the volume gave back, once it settles.
        let settled = Volume.settledGain(since: freeBefore)
        let readingAfter = Descriptors.read()
        let after = Descriptors.measure(selected, reading: readingAfter)
        record["after"] = after.map(\.summary)
        if let last = settled.lastReading { record["freeAfter"] = last }
        if let gained = settled.gained { record["freedBytes"] = gained }
        Journal.record("remove", note: nil, fields: record)

        Log.line()
        Log.line("Free space after:  " + Format.bytes(settled.lastReading))
        Log.line("Freed (volume delta, settled): " + (settled.gained.map { Format.bytes($0) } ?? "under the noise floor or still moving"))
        Log.line()
        printMeasurements(after, reading: readingAfter)
        Log.line()
        Log.line("Run `aimodels snapshot --note \"after restart\"` later, and again after a day online.")
        return releaseFailures.isEmpty && (released.count == releasing.count)
    }

    // MARK: restore

    static func restore(sets: String?, yes: Bool) -> Bool {
        header()
        let selected: [ModelSet]
        do { selected = try Catalog.select(sets) } catch { Log.fail("\(error)") }
        printProfile()
        let blocks = Profile.installedBlocks()
        let viaService = MacOS.releasesThroughService
        Log.line()
        Log.line("Plan")
        if !blocks.isEmpty { Log.line("  1. remove the Purge profile (macOS lets only you do that)") }
        if viaService {
            Log.line("  2. ask the asset service to subscribe to " + selected.map(\.name).joined(separator: ", ") + " again; macOS downloads in the background")
        } else {
            Log.line("  2. open Apple Intelligence & Siri so you can turn Apple Intelligence on; macOS downloads in the background")
        }
        Log.line()
        if !yes {
            guard isatty(STDIN_FILENO) == 1 else { Log.fail("run it in a terminal, or add --yes") }
            guard Shell.ask("Go ahead?") else {
                Log.line("Nothing changed.")
                return true
            }
        }
        var record: [String: Any] = ["sets": selected.map(\.name)]
        if let free = Volume.freeBytes() { record["freeBefore"] = free }

        if !blocks.isEmpty {
            Shell.openSettings(Shell.profilesPane)
            Log.line("In System Settings, select \"Purge: Apple Intelligence models removed\" and click Remove.")
            Log.line("From a terminal instead: sudo profiles remove -identifier \(Profile.identifier)")
            guard Shell.waitFor("waiting for the profile to go", minutes: 10, { Profile.installedBlocks().isEmpty }) else {
                Log.error("the profile is still installed, so downloads stay blocked; nothing else was changed")
                Journal.record("restore", note: "stopped at the profile", fields: record)
                return false
            }
            Log.line("Profile removed")
            record["profile"] = "removed"
        }

        if viaService {
            let flight = preflight(selected, options: PurgeOptions(), checkService: true, checkPurge: false)
            guard flight.frameworkLoads, !flight.mapped.isEmpty else {
                Log.error("this macOS does not match the catalog, so nothing is sent")
                Journal.record("restore", note: "catalog mismatch", fields: record)
                return false
            }
            for set in flight.mapped {
                for type in set.recovery?.additionalAssetSets ?? [] {
                    let mapping = Worker.run("uaf-asset-type", ["assetSet": type], timeout: 30)
                    if mapping.result["assetType"] as? String != type {
                        Log.warn("\(set.name): download dependency \(type) is not known to this macOS")
                    }
                }
            }
            let recoveries = flight.mapped.compactMap(\.recovery)
            let names = recoveries.map(\.name)
            let unsubscribe = Worker.run("uaf-unsubscribe", ["subscriber": Catalog.subscriber, "names": names], timeout: 70)
            if !unsubscribe.ok { Log.warn("unsubscribe (clears an older request of ours; harmless when there is none): " + unsubscribe.problem) }
            let subscriptions: [[String: Any]] = recoveries.map { recovery -> [String: Any] in
                ["name": recovery.name, "usageAliases": recovery.usageAliases, "assetSetUsages": recovery.assetSetUsages]
            }
            let subscribe = Worker.run("uaf-subscribe", ["subscriber": Catalog.subscriber, "subscriptions": subscriptions], timeout: 70)
            record["subscribed"] = subscribe.ok ? names : []
            if subscribe.ok {
                Log.line("Subscribed: " + names.joined(separator: ", ") + ". macOS downloads the models in the background.")
            } else {
                Log.error("subscribe failed: " + subscribe.problem)
                record["subscribeProblem"] = subscribe.problem
            }
            Journal.record("restore", note: nil, fields: record)
            return subscribe.ok
        }

        Shell.openSettings(Shell.siriPane)
        Log.line("Turn Apple Intelligence on in System Settings > Apple Intelligence & Siri, then press Return here.")
        _ = readLine()
        Journal.record("restore", note: nil, fields: record)
        Log.line("macOS downloads the models in the background. Check with `aimodels snapshot --note \"after download again\"` later.")
        return true
    }

    // MARK: snapshot

    static func snapshot(note: String?) {
        header()
        let reading = Descriptors.read()
        let measured = Descriptors.measure(Catalog.sets, reading: reading)
        printMeasurements(measured, reading: reading)
        Log.line()
        printProfile()
        Log.line("Free space on /: " + Format.bytes(Volume.freeBytes()))
        let entry = Journal.record("snapshot", note: note, fields: [
            "sets": measured.map(\.summary), "blocks": Profile.installedBlocks(), "errors": reading.errors,
        ])
        Log.line("Recorded to \(Journal.file.path): " + Format.json(entry, pretty: false))
    }
}

