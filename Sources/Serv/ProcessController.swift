import Foundation
import ServCore
import Darwin

@MainActor
final class ProcessController {
    enum RuntimePhase {
        case stopped
        case starting
        case ready
        case running
        case exited
        case failed
    }

    struct ProcessState {
        var isRunning: Bool
        var status: String
        var phase: RuntimePhase
        var lastErrorPreview: String?
    }

    private let logDirectory: URL
    private var processes: [String: Process] = [:]
    private var runningPorts: [String: Int] = [:]
    private var states: [String: ProcessState] = [:]
    var onStateChange: (() -> Void)?

    init(fileManager: FileManager = .default) {
        logDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Serv", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
        try? fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
    }

    func state(for project: Project, command: Project.Command) -> ProcessState {
        let processKey = key(project: project, command: command)
        guard let process = processes[processKey] else {
            return states[processKey] ?? ProcessState(
                isRunning: false,
                status: "Stopped",
                phase: .stopped,
                lastErrorPreview: nil
            )
        }

        if process.isRunning {
            return states[processKey] ?? ProcessState(
                isRunning: true,
                status: "Running",
                phase: .running,
                lastErrorPreview: nil
            )
        }

        processes[processKey] = nil
        return states[processKey] ?? ProcessState(
            isRunning: false,
            status: "Stopped",
            phase: .stopped,
            lastErrorPreview: nil
        )
    }

    func toggle(project: Project, command: Project.Command, portOverride: Int? = nil) -> String {
        let processKey = key(project: project, command: command)
        if let process = processes[processKey], process.isRunning {
            return stop(project: project, command: command, process: process)
        }

        return start(project: project, command: command, portOverride: portOverride)
    }

    func stop(project: Project) {
        for command in project.commands {
            stop(project: project, command: command)
        }
    }

    func stop(project: Project, command: Project.Command) {
        let processKey = key(project: project, command: command)
        guard let process = processes[processKey], process.isRunning else {
            processes[processKey] = nil
            runningPorts[processKey] = nil
            states[processKey] = ProcessState(
                isRunning: false,
                status: "Stopped",
                phase: .stopped,
                lastErrorPreview: nil
            )
            return
        }
        _ = stop(project: project, command: command, process: process)
    }

    func stopAll() {
        for process in processes.values where process.isRunning {
            terminateProcessTree(rootPID: process.processIdentifier)
            process.terminate()
        }
        processes.removeAll()
        runningPorts.removeAll()
        for key in states.keys {
            states[key] = ProcessState(
                isRunning: false,
                status: "Stopped",
                phase: .stopped,
                lastErrorPreview: nil
            )
        }
    }

    func ensureLogFile(for project: Project, command: Project.Command) -> URL {
        let url = logURL(for: project, command: command)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        return url
    }

    func runningPort(for project: Project, command: Project.Command) -> Int? {
        runningPorts[key(project: project, command: command)]
    }

    private func start(project: Project, command: Project.Command, portOverride: Int?) -> String {
        let process = Process()
        let launchArguments = launchArguments(for: command, portOverride: portOverride)
        process.currentDirectoryURL = URL(fileURLWithPath: command.workingDirectoryPath, isDirectory: true)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command.executable] + launchArguments
        process.environment = ProcessInfo.processInfo.environment.merging(command.environment) { _, new in new }

        let processKey = key(project: project, command: command)
        let logURL = ensureLogFile(for: project, command: command)
        guard let logHandle = try? FileHandle(forWritingTo: logURL) else {
            return "Failed: could not open log file"
        }
        _ = try? logHandle.seekToEnd()
        writeLogHeader(to: logHandle, project: project, command: command, arguments: launchArguments)
        states[processKey] = ProcessState(
            isRunning: true,
            status: "Starting",
            phase: .starting,
            lastErrorPreview: nil
        )

        process.standardOutput = logHandle
        process.standardError = logHandle
        process.terminationHandler = { [weak self] terminatedProcess in
            Task { @MainActor in
                if self?.processes[processKey] === terminatedProcess {
                    self?.processes[processKey] = nil
                    self?.runningPorts[processKey] = nil
                    let exitCode = terminatedProcess.terminationStatus
                    let errorPreview = self?.lastErrorPreview(from: logURL)
                    self?.states[processKey] = ProcessState(
                        isRunning: false,
                        status: exitCode == 0 ? "Exited" : "Exited with code \(exitCode)",
                        phase: exitCode == 0 ? .exited : .failed,
                        lastErrorPreview: errorPreview
                    )
                    self?.onStateChange?()
                }
            }
        }

        do {
            try process.run()
            try? logHandle.close()
            processes[processKey] = process
            let port = portOverride ?? command.preferredPort
            runningPorts[processKey] = port
            if let port {
                scheduleHealthCheck(processKey: processKey, port: port, healthURLString: command.healthURLString)
            } else {
                states[processKey] = ProcessState(
                    isRunning: true,
                    status: "Running",
                    phase: .running,
                    lastErrorPreview: nil
                )
            }
            return "Started \(command.name)"
        } catch {
            try? logHandle.close()
            states[processKey] = ProcessState(
                isRunning: false,
                status: "Failed",
                phase: .failed,
                lastErrorPreview: error.localizedDescription
            )
            return "Failed: \(error.localizedDescription)"
        }
    }

    private func stop(project: Project, command: Project.Command, process: Process) -> String {
        terminateProcessTree(rootPID: process.processIdentifier)
        process.terminate()
        let processKey = key(project: project, command: command)
        processes[processKey] = nil
        runningPorts[processKey] = nil
        states[processKey] = ProcessState(
            isRunning: false,
            status: "Stopped",
            phase: .stopped,
            lastErrorPreview: nil
        )
        return "Stopped \(command.name)"
    }

    private func logURL(for project: Project, command: Project.Command) -> URL {
        let safeName = project.name
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let safeCommand = command.name
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return logDirectory.appendingPathComponent("\(safeName)-\(safeCommand)-\(command.id.uuidString).log")
    }

    private func writeLogHeader(
        to handle: FileHandle,
        project: Project,
        command: Project.Command,
        arguments: [String]
    ) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let display = ([command.executable] + arguments).joined(separator: " ")
        let header = "\n\n=== \(timestamp) \(project.name): \(display) ===\n"
        if let data = header.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
    }

    private func launchArguments(for command: Project.Command, portOverride: Int?) -> [String] {
        guard let portOverride else {
            return command.arguments
        }

        if command.portOverrideStrategy == .replaceInShellCommand,
           command.executable == "/bin/zsh",
           command.arguments.count == 2,
           command.arguments[0] == "-lc",
           let preferredPort = command.preferredPort {
            return ["-lc", replacePort(preferredPort, with: portOverride, in: command.arguments[1])]
        }

        guard command.portOverrideStrategy == .appendFlag else {
            return command.arguments
        }

        switch command.executable {
        case "npm", "pnpm", "bun":
            return command.arguments + ["--", "--port", "\(portOverride)"]
        case "yarn":
            return command.arguments + ["--port", "\(portOverride)"]
        default:
            return command.arguments + ["--port", "\(portOverride)"]
        }
    }

    private func replacePort(_ oldPort: Int, with newPort: Int, in commandLine: String) -> String {
        let replacements = [
            (#"PORT=\#(oldPort)(?=\s|$)"#, "PORT=\(newPort)"),
            (#"--port=\#(oldPort)(?=\s|$)"#, "--port=\(newPort)"),
            (#"--port\s+\#(oldPort)(?=\s|$)"#, "--port \(newPort)"),
            (#"-p\s+\#(oldPort)(?=\s|$)"#, "-p \(newPort)")
        ]

        for replacement in replacements {
            if let regex = try? NSRegularExpression(pattern: replacement.0) {
                let range = NSRange(commandLine.startIndex..<commandLine.endIndex, in: commandLine)
                if regex.firstMatch(in: commandLine, range: range) != nil {
                    return regex.stringByReplacingMatches(
                        in: commandLine,
                        range: range,
                        withTemplate: replacement.1
                    )
                }
            }
        }

        return commandLine
    }

    private func key(project: Project, command: Project.Command) -> String {
        "\(project.id.uuidString):\(command.id.uuidString)"
    }

    private func scheduleHealthCheck(processKey: String, port: Int, healthURLString: String?) {
        let url = healthURLString.flatMap(URL.init(string:)) ?? URL(string: "http://localhost:\(port)")
        guard let url else {
            states[processKey] = ProcessState(
                isRunning: true,
                status: "Running on port \(port)",
                phase: .running,
                lastErrorPreview: nil
            )
            return
        }

        Task { [weak self] in
            for _ in 0..<24 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self,
                      self.processes[processKey]?.isRunning == true else {
                    return
                }

                if await Self.healthCheckSucceeds(url: url) {
                    self.states[processKey] = ProcessState(
                        isRunning: true,
                        status: "Ready on port \(port)",
                        phase: .ready,
                        lastErrorPreview: nil
                    )
                    self.onStateChange?()
                    return
                }
            }

            guard let self,
                  self.processes[processKey]?.isRunning == true else {
                return
            }
            self.states[processKey] = ProcessState(
                isRunning: true,
                status: "Running on port \(port), health check pending",
                phase: .running,
                lastErrorPreview: nil
            )
            self.onStateChange?()
        }
    }

    nonisolated private static func healthCheckSucceeds(url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 2

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }
            return (200..<500).contains(httpResponse.statusCode)
        } catch {
            return false
        }
    }

    private func lastErrorPreview(from logURL: URL) -> String? {
        guard let data = try? Data(contentsOf: logURL),
              let contents = String(data: data, encoding: .utf8) else {
            return nil
        }

        let interestingLines = contents
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .suffix(20)
        let preview = interestingLines
            .reversed()
            .first { line in
                let lowercased = line.lowercased()
                return lowercased.contains("error")
                    || lowercased.contains("failed")
                    || lowercased.contains("exception")
                    || lowercased.contains("eaddrinuse")
            }
            ?? interestingLines.last

        guard let preview, !preview.isEmpty else {
            return nil
        }
        return String(preview.prefix(180))
    }

    func terminateExternalProcessTree(rootPID: Int32) {
        terminateProcessTree(rootPID: rootPID)
        kill(rootPID, SIGTERM)
    }

    private func terminateProcessTree(rootPID: Int32) {
        let descendants = descendantPIDs(of: rootPID)
        for pid in descendants.reversed() {
            kill(pid, SIGTERM)
        }
    }

    private func descendantPIDs(of pid: Int32) -> [Int32] {
        let children = childPIDs(of: pid)
        return children + children.flatMap(descendantPIDs)
    }

    private func childPIDs(of pid: Int32) -> [Int32] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-P", "\(pid)"]
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let outputString = String(data: data, encoding: .utf8) else {
            return []
        }

        return outputString
            .split(separator: "\n")
            .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}
