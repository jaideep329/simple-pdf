import Foundation

struct AgentProcessResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool
}

/// Spawns local agent CLIs. GUI apps inherit a minimal PATH (no Homebrew/npm
/// dirs), so the user's login shell PATH is captured once via `zsh -l` and used
/// for both binary resolution and the child environment — that also keeps
/// shebang interpreters (e.g. `env node`) resolvable.
enum AgentCLIProcess {
    private static let pathLock = NSLock()
    private static var cachedPATH: String?

    static func effectivePATH() -> String {
        pathLock.lock()
        defer { pathLock.unlock() }

        if let cachedPATH { return cachedPATH }

        var components: [String] = []
        if let loginPATH = captureLoginShellPATH() {
            components += loginPATH.split(separator: ":").map(String.init)
        }
        if let envPATH = ProcessInfo.processInfo.environment["PATH"] {
            components += envPATH.split(separator: ":").map(String.init)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        components += [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/bin",
            "/usr/bin",
            "/bin"
        ]

        var seen = Set<String>()
        let path = components.filter { seen.insert($0).inserted }.joined(separator: ":")
        cachedPATH = path
        return path
    }

    static func resolveExecutable(named name: String) -> String? {
        let fileManager = FileManager.default
        for directory in effectivePATH().split(separator: ":") {
            let candidate = "\(directory)/\(name)"
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory),
               !isDirectory.boolValue,
               fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func captureLoginShellPATH() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "printf %s \"$PATH\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (path?.isEmpty == false) ? path : nil
    }

    /// Runs the CLI to completion off the main thread. Honors Task cancellation
    /// (SIGTERM) and enforces `timeout` (SIGTERM, then SIGKILL after a grace
    /// period). stdin is /dev/null so an unexpected interactive prompt makes the
    /// CLI fail fast instead of hanging.
    static func run(
        executablePath: String,
        arguments: [String],
        workingDirectory: URL,
        timeout: TimeInterval
    ) async throws -> AgentProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = effectivePATH()
        environment["NO_COLOR"] = "1"
        environment["TERM"] = "dumb"
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw AgentCLIError.launchFailed(error.localizedDescription)
        }

        let stdoutBuffer = PipeBuffer()
        let stderrBuffer = PipeBuffer()
        let drainGroup = DispatchGroup()
        for (pipe, buffer) in [(stdoutPipe, stdoutBuffer), (stderrPipe, stderrBuffer)] {
            drainGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                buffer.append(pipe.fileHandleForReading.readDataToEndOfFile())
                drainGroup.leave()
            }
        }

        let pid = process.processIdentifier
        let timedOutFlag = AtomicFlag()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            if process.isRunning {
                timedOutFlag.set()
                kill(pid, SIGTERM)
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout + 5) {
            if process.isRunning {
                kill(pid, SIGKILL)
            }
        }

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .utility).async {
                    process.waitUntilExit()
                    drainGroup.wait()
                    continuation.resume()
                }
            }
        } onCancel: {
            kill(pid, SIGTERM)
        }

        try Task.checkCancellation()

        return AgentProcessResult(
            exitCode: process.terminationStatus,
            stdout: stdoutBuffer.text,
            stderr: stderrBuffer.text,
            timedOut: timedOutFlag.isSet
        )
    }
}

private final class PipeBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
