import Foundation

/// Runs a program without a shell and returns its output, with a deadline. The
/// child's pipes are drained on background threads so a chatty child can never
/// deadlock the wait (the trap Purge's ProcessRunner documents).
enum Shell {
    struct Result {
        let status: Int32
        let stdout: Data
        let stderr: Data
        let timedOut: Bool
        /// Set when the child died from a signal, such as a crash in a private call.
        let signal: Int32?

        var ok: Bool { !timedOut && signal == nil && status == 0 }
        var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
        var stderrText: String { String(decoding: stderr, as: UTF8.self) }
    }

    static func run(_ path: String, _ arguments: [String], stdin input: Data? = nil,
                    timeout: TimeInterval) -> Result? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe = Pipe()
        if input == nil {
            process.standardInput = FileHandle.nullDevice
        } else {
            process.standardInput = inPipe
        }
        do { try process.run() } catch { return nil }
        if let input {
            inPipe.fileHandleForWriting.write(input)
            try? inPipe.fileHandleForWriting.close()
        }

        let group = DispatchGroup()
        var out = Data()
        var err = Data()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            out = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            err = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while process.isRunning {
            if Date() >= deadline {
                timedOut = true
                process.terminate()
                Thread.sleep(forTimeInterval: 2)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        process.waitUntilExit()
        // The child is gone, so both pipes reach EOF unless a grandchild holds them.
        if group.wait(timeout: .now() + 5) == .timedOut {
            return Result(status: process.terminationStatus, stdout: out, stderr: err, timedOut: true, signal: nil)
        }
        let signal: Int32? = process.terminationReason == .uncaughtSignal ? process.terminationStatus : nil
        return Result(status: process.terminationStatus, stdout: out, stderr: err, timedOut: timedOut, signal: signal)
    }

    static func open(_ target: String) {
        _ = run("/usr/bin/open", [target], timeout: 20)
    }

    /// Opens System Settings at a pane, trying each URL until one is accepted.
    static func openSettings(_ urls: [String]) {
        for url in urls {
            if let result = run("/usr/bin/open", [url], timeout: 20), result.ok { return }
        }
    }

    static let profilesPane = [
        "x-apple.systempreferences:com.apple.Profiles-Settings.extension",
        "x-apple.systempreferences:com.apple.preferences.configurationprofiles",
    ]

    /// Apple Intelligence & Siri on macOS 15 and 26.
    static let siriPane = [
        "x-apple.systempreferences:com.apple.Siri-Settings.extension",
        "x-apple.systempreferences:com.apple.preference.speech",
    ]

    /// Polls `condition` with a spinner until it holds or `minutes` pass.
    static func waitFor(_ what: String, minutes: Double, _ condition: () -> Bool) -> Bool {
        let spinner = Array("|/-\\")
        let deadline = Date().addingTimeInterval(minutes * 60)
        var tick = 0
        defer { print("\r\u{1B}[K", terminator: "") }
        while Date() < deadline {
            if condition() { return true }
            print("\r  \(spinner[tick % spinner.count]) \(what)", terminator: "")
            fflush(stdout)
            tick += 1
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    static func ask(_ question: String) -> Bool {
        print(question + " [y/N] ", terminator: "")
        fflush(stdout)
        guard let answer = readLine() else { return false }
        return ["y", "yes"].contains(answer.trimmingCharacters(in: .whitespaces).lowercased())
    }
}
