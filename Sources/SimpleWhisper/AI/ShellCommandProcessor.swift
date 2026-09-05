import Foundation

/// Runs a shell command template. Instructions are passed through the `SW_PROMPT`
/// environment variable (no quoting issues); the text is written to stdin; stdout is the result.
final class ShellCommandProcessor: TextProcessor {
    let commandTemplate: String
    let timeout: TimeInterval

    init(commandTemplate: String, timeout: TimeInterval = 120) {
        self.commandTemplate = commandTemplate
        self.timeout = timeout
    }

    /// Collects pipe output as it arrives so neither stream can fill up and block the child.
    private final class PipeCollector {
        let pipe = Pipe()
        private var data = Data()
        private let lock = NSLock()

        init() {
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let chunk = handle.availableData
                guard let self, !chunk.isEmpty else { return }
                self.lock.withLock { self.data.append(chunk) }
            }
        }

        func finish() -> String {
            pipe.fileHandleForReading.readabilityHandler = nil
            let rest = pipe.fileHandleForReading.readDataToEndOfFile()
            return lock.withLock {
                data.append(rest)
                return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
        }
    }

    private final class Flag {
        private var storage = false
        private let lock = NSLock()
        var value: Bool {
            get { lock.withLock { storage } }
            set { lock.withLock { storage = newValue } }
        }
    }

    func process(text: String, instructions: String) async throws -> String {
        let command = commandTemplate.replacingOccurrences(of: "{prompt}", with: "\"$SW_PROMPT\"")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        var environment = ProcessInfo.processInfo.environment
        environment["SW_PROMPT"] = instructions
        environment["PATH"] = (environment["PATH"] ?? "") + ":\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin"
        process.environment = environment

        let stdin = Pipe()
        let stdout = PipeCollector()
        let stderr = PipeCollector()
        process.standardInput = stdin
        process.standardOutput = stdout.pipe
        process.standardError = stderr.pipe

        let started = Date()
        let timeoutSeconds = timeout
        let timedOut = Flag()
        let timer = DispatchWorkItem {
            if process.isRunning {
                timedOut.value = true
                DebugLog.write("Shell: timeout after \(Int(timeoutSeconds)) s, terminating")
                process.terminate()
            }
        }

        DebugLog.write("Shell: start `\(command.prefix(120))`")
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                process.terminationHandler = { finished in
                    timer.cancel()
                    let output = stdout.finish()
                    let errors = stderr.finish()
                    let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
                    DebugLog.write("Shell: exit \(finished.terminationStatus) reason=\(finished.terminationReason.rawValue) in \(elapsed) s, stdout=\(output.count) chars, stderr=\(errors.prefix(200))")
                    if timedOut.value {
                        continuation.resume(throwing: ProcessingError.timeout)
                        return
                    }
                    // Exit 143 = the tool caught SIGTERM; if it already produced output, keep it.
                    let sigtermWithOutput = finished.terminationStatus == 143 && !output.isEmpty
                    if finished.terminationStatus != 0 && !sigtermWithOutput {
                        let message = [errors, output].filter { !$0.isEmpty }.joined(separator: " | ")
                        continuation.resume(throwing: ProcessingError.commandFailed("exit code \(finished.terminationStatus)" + (message.isEmpty ? "" : ": \(message.prefix(300))")))
                        return
                    }
                    if output.isEmpty {
                        continuation.resume(throwing: ProcessingError.emptyOutput)
                        return
                    }
                    continuation.resume(returning: output)
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: ProcessingError.commandFailed(error.localizedDescription))
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timer)
                DispatchQueue.global(qos: .userInitiated).async {
                    if let data = text.data(using: .utf8) {
                        stdin.fileHandleForWriting.write(data)
                    }
                    try? stdin.fileHandleForWriting.close()
                }
            }
        } onCancel: {
            DebugLog.write("Shell: task cancelled, terminating child")
            if process.isRunning { process.terminate() }
        }
    }
}
