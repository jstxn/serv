import AppKit

enum StatusIconFactory {
    static func icon(for indicator: StatusIndicator) -> NSImage {
        let color: NSColor
        switch indicator {
        case .stopped:
            color = .systemGray
        case .starting:
            color = .systemYellow
        case .running:
            color = .systemGreen
        case .external:
            color = .systemYellow
        case .problem:
            color = .systemRed
        }

        let size = NSSize(width: 10, height: 10)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 8, height: 8)).fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}

enum PortInspector {
    static func isPortTakenNow(_ port: Int) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    static func listeningPIDs(on port: Int) -> [Int32] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-t", "-iTCP:\(port)", "-sTCP:LISTEN"]
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

        return Array(Set(outputString
            .split(separator: "\n")
            .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }))
            .sorted()
    }

    static func processCommandLines(for pids: [Int32]) -> [Int32: String] {
        pids.reduce(into: [:]) { details, pid in
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/ps")
            process.arguments = ["-p", "\(pid)", "-o", "command="]
            process.standardOutput = output
            process.standardError = Pipe()

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return
            }

            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard let command = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !command.isEmpty else {
                return
            }
            details[pid] = command
        }
    }
}

enum ComposeRuntime {
    static func runningServices(in workingDirectoryPath: String) -> Set<String> {
        let process = Process()
        let output = Pipe()
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectoryPath, isDirectory: true)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["docker", "compose", "ps", "--status", "running", "--services"]
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0,
              let outputString = String(data: data, encoding: .utf8) else {
            return []
        }

        return Set(outputString
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
    }

    static func stop(in workingDirectoryPath: String, services: [String]) -> Bool {
        let process = Process()
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectoryPath, isDirectory: true)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["docker", "compose", "stop"] + services
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
