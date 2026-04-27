import Foundation

public enum PortOverrideStrategy: String, Codable, Sendable {
    case appendFlag
    case replaceInShellCommand
}

public enum CommandGroup: String, Codable, CaseIterable, Sendable {
    case compose = "Compose"
    case frontend = "Frontend"
    case api = "API"
    case worker = "Worker"
    case custom = "Custom"
    case other = "Other"

    public static func infer(
        name: String,
        display: String,
        reason: String,
        workingDirectoryPath: String,
        executable: String,
        arguments: [String]
    ) -> CommandGroup {
        let searchable = [
            name,
            display,
            reason,
            workingDirectoryPath,
            executable,
            arguments.joined(separator: " ")
        ]
        .joined(separator: " ")
        .lowercased()

        if executable == "docker", Array(arguments.prefix(2)) == ["compose", "up"] {
            return .compose
        }
        if reason == "Custom command" {
            return .custom
        }
        if searchable.contains("worker") || searchable.contains("queue") || searchable.contains("cron") {
            return .worker
        }
        if searchable.contains("api") || searchable.contains("server") || searchable.contains("backend") {
            return .api
        }
        if isPackageDevCommand(searchable: searchable, executable: executable) {
            return .frontend
        }
        if searchable.contains("frontend")
            || searchable.contains("web")
            || searchable.contains("next")
            || searchable.contains("vite")
            || searchable.contains("astro")
            || searchable.contains("react")
            || searchable.contains("vue") {
            return .frontend
        }
        return .other
    }

    private static func isPackageDevCommand(searchable: String, executable: String) -> Bool {
        guard ["npm", "pnpm", "yarn", "bun"].contains(executable) else {
            return false
        }

        return [
            "package.json scripts.dev",
            "package.json scripts.start",
            "package.json scripts.serve",
            "package.json scripts.preview",
            "package.json scripts.web"
        ].contains { searchable.contains($0) }
    }
}

public struct DevCommand: Equatable, Sendable {
    public let name: String
    public let executable: String
    public let arguments: [String]
    public let display: String
    public let reason: String
    public let workingDirectoryPath: String
    public let preferredPort: Int?
    public let portOverrideStrategy: PortOverrideStrategy?
    public let group: CommandGroup
    public let environment: [String: String]
    public let healthURLString: String?

    public init(
        name: String,
        executable: String,
        arguments: [String],
        display: String,
        reason: String,
        workingDirectoryPath: String,
        preferredPort: Int? = nil,
        portOverrideStrategy: PortOverrideStrategy? = nil,
        group: CommandGroup? = nil,
        environment: [String: String] = [:],
        healthURLString: String? = nil
    ) {
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.display = display
        self.reason = reason
        self.workingDirectoryPath = workingDirectoryPath
        self.preferredPort = preferredPort
        self.portOverrideStrategy = portOverrideStrategy
        self.group = group ?? CommandGroup.infer(
            name: name,
            display: display,
            reason: reason,
            workingDirectoryPath: workingDirectoryPath,
            executable: executable,
            arguments: arguments
        )
        self.environment = environment
        self.healthURLString = healthURLString
    }
}

public enum DevCommandDetector {
    private static let scriptPreference = [
        "dev",
        "start",
        "serve",
        "preview",
        "web",
        "server"
    ]

    private static let ignoredDirectoryNames = [
        ".build",
        ".git",
        ".next",
        ".turbo",
        "coverage",
        "dist",
        "node_modules"
    ]

    public static func detect(in directory: URL, fileManager: FileManager = .default) -> DevCommand? {
        detectAll(in: directory, fileManager: fileManager).first
    }

    public static func detectAll(in directory: URL, fileManager: FileManager = .default) -> [DevCommand] {
        guard directory.isFileURL else {
            return []
        }

        var commands: [DevCommand] = []
        if let packageCommand = detectPackageCommand(in: directory, rootDirectory: directory, fileManager: fileManager) {
            commands.append(packageCommand)
        }

        if fileManager.fileExists(atPath: directory.appendingPathComponent("Makefile").path),
           let makeCommand = detectMakeCommand(in: directory, rootDirectory: directory) {
            commands.append(makeCommand)
        }

        commands.append(contentsOf: detectComposeCommands(in: directory, fileManager: fileManager))
        commands.append(contentsOf: detectNestedPackageCommands(in: directory, fileManager: fileManager))
        return unique(commands)
    }

    public static func shellCommand(name: String, commandLine: String, workingDirectory: URL) -> DevCommand {
        let preferredPort = preferredPort(in: commandLine, packageRoot: nil)
        return DevCommand(
            name: name,
            executable: "/bin/zsh",
            arguments: ["-lc", commandLine],
            display: commandLine,
            reason: "Custom command",
            workingDirectoryPath: workingDirectory.path,
            preferredPort: preferredPort,
            portOverrideStrategy: preferredPort == nil ? nil : .replaceInShellCommand
        )
    }

    private static func detectPackageCommand(
        in directory: URL,
        rootDirectory: URL,
        fileManager: FileManager
    ) -> DevCommand? {
        let packageURL = directory.appendingPathComponent("package.json")
        guard
            let data = try? Data(contentsOf: packageURL),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let scripts = root["scripts"] as? [String: Any]
        else {
            return nil
        }

        let normalizedScripts = scripts.compactMapValues { $0 as? String }
        guard let script = scriptPreference.first(where: { normalizedScripts[$0] != nil }),
              let scriptValue = normalizedScripts[script] else {
            return nil
        }

        let runner = packageRunner(in: directory, fileManager: fileManager)
        let arguments: [String]
        switch runner {
        case "npm":
            arguments = ["run", script]
        case "yarn":
            arguments = [script]
        case "pnpm":
            arguments = ["run", script]
        case "bun":
            arguments = ["run", script]
        default:
            arguments = ["run", script]
        }

        let display = ([runner] + arguments).joined(separator: " ")
        return DevCommand(
            name: packageCommandName(for: directory, rootDirectory: rootDirectory, script: script),
            executable: runner,
            arguments: arguments,
            display: display,
            reason: packageReason(for: directory, rootDirectory: rootDirectory, script: script),
            workingDirectoryPath: normalizedPath(directory),
            preferredPort: preferredPort(in: scriptValue, packageRoot: root),
            portOverrideStrategy: .appendFlag,
            group: packageGroup(
                scriptName: script,
                scriptValue: scriptValue,
                packageRoot: root,
                directory: directory,
                rootDirectory: rootDirectory
            )
        )
    }

    private static func detectComposeCommands(in directory: URL, fileManager: FileManager) -> [DevCommand] {
        let composeURLs = composeFiles(in: directory, fileManager: fileManager)
        guard let composeURL = composeURLs.first else {
            return []
        }

        let servicePorts = composeHostPorts(in: composeURLs)
        var commands = [
            DevCommand(
                name: "All services",
                executable: "docker",
                arguments: ["compose", "up"],
                display: "docker compose up",
                reason: composeURL.lastPathComponent,
                workingDirectoryPath: normalizedPath(directory),
                preferredPort: nil
            )
        ]

        let services = composeServices(in: composeURLs)
        if services.contains("proxy"), services.contains("screener") {
            commands.append(
                DevCommand(
                    name: "Screener + proxy",
                    executable: "docker",
                    arguments: ["compose", "up", "screener", "proxy"],
                    display: "docker compose up screener proxy",
                    reason: "\(composeURL.lastPathComponent) services",
                    workingDirectoryPath: normalizedPath(directory),
                    preferredPort: servicePorts["proxy"] ?? servicePorts["screener"]
                )
            )
        }

        commands.append(contentsOf: services.map { service in
            DevCommand(
                name: service,
                executable: "docker",
                arguments: ["compose", "up", service],
                display: "docker compose up \(service)",
                reason: "\(composeURL.lastPathComponent) service \(service)",
                workingDirectoryPath: normalizedPath(directory),
                preferredPort: servicePorts[service]
            )
        })

        return commands
    }

    private static func detectNestedPackageCommands(in directory: URL, fileManager: FileManager) -> [DevCommand] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var commands: [DevCommand] = []
        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isDirectoryKey]) else {
                continue
            }

            if resourceValues.isDirectory == true {
                if ignoredDirectoryNames.contains(fileURL.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard fileURL.lastPathComponent == "package.json",
                  fileURL.deletingLastPathComponent() != directory,
                  let command = detectPackageCommand(
                    in: fileURL.deletingLastPathComponent(),
                    rootDirectory: directory,
                    fileManager: fileManager
                  ) else {
                continue
            }

            commands.append(command)
        }

        return commands.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func packageRunner(in directory: URL, fileManager: FileManager) -> String {
        if fileManager.fileExists(atPath: directory.appendingPathComponent("pnpm-lock.yaml").path) {
            return "pnpm"
        }
        if fileManager.fileExists(atPath: directory.appendingPathComponent("yarn.lock").path) {
            return "yarn"
        }
        if fileManager.fileExists(atPath: directory.appendingPathComponent("bun.lock").path)
            || fileManager.fileExists(atPath: directory.appendingPathComponent("bun.lockb").path) {
            return "bun"
        }
        return "npm"
    }

    private static func detectMakeCommand(in directory: URL, rootDirectory: URL) -> DevCommand? {
        let makefileURL = directory.appendingPathComponent("Makefile")
        guard let contents = try? String(contentsOf: makefileURL, encoding: .utf8) else {
            return nil
        }

        let targets = contents
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard !line.hasPrefix("\t"),
                      !line.trimmingCharacters(in: .whitespaces).hasPrefix("#"),
                      let colon = line.firstIndex(of: ":") else {
                    return nil
                }

                let target = line[..<colon].trimmingCharacters(in: .whitespaces)
                guard !target.isEmpty, !target.contains(" ") else {
                    return nil
                }

                return target
            }

        guard let target = scriptPreference.first(where: { targets.contains($0) }) else {
            return nil
        }

        return DevCommand(
            name: "make \(target)",
            executable: "make",
            arguments: [target],
            display: "make \(target)",
            reason: "Makefile target \(target)",
            workingDirectoryPath: normalizedPath(directory),
            preferredPort: nil
        )
    }

    private static func composeFiles(in directory: URL, fileManager: FileManager) -> [URL] {
        [
            "docker-compose.yml",
            "docker-compose.yaml",
            "docker-compose.override.yml",
            "docker-compose.override.yaml",
            "compose.yml",
            "compose.yaml",
            "compose.override.yml",
            "compose.override.yaml"
        ]
        .map { directory.appendingPathComponent($0) }
        .filter { fileManager.fileExists(atPath: $0.path) }
    }

    private static func composeServices(in composeURLs: [URL]) -> [String] {
        Array(Set(composeURLs.flatMap(composeServices))).sorted()
    }

    private static func composeServices(in composeURL: URL) -> [String] {
        guard let contents = try? String(contentsOf: composeURL, encoding: .utf8) else {
            return []
        }

        var inServices = false
        var services: [String] = []

        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
                continue
            }

            if trimmed == "services:" {
                inServices = true
                continue
            }

            guard inServices else {
                continue
            }

            if !line.hasPrefix(" ") && !line.hasPrefix("\t") {
                break
            }

            guard line.hasPrefix("  "), !line.hasPrefix("    ") else {
                continue
            }

            let candidate = trimmed.replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: "'", with: "")
            guard let colon = candidate.firstIndex(of: ":") else {
                continue
            }

            let service = String(candidate[..<colon])
            if service.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil {
                services.append(service)
            }
        }

        return services.sorted()
    }

    private static func composeHostPorts(in composeURLs: [URL]) -> [String: Int] {
        composeURLs.reduce(into: [:]) { ports, composeURL in
            for (service, port) in composeHostPorts(in: composeURL) {
                ports[service] = port
            }
        }
    }

    private static func composeHostPorts(in composeURL: URL) -> [String: Int] {
        guard let contents = try? String(contentsOf: composeURL, encoding: .utf8) else {
            return [:]
        }

        var inServices = false
        var currentService: String?
        var inPorts = false
        var portsIndent = 0
        var ports: [String: Int] = [:]

        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
                continue
            }

            if trimmed == "services:" {
                inServices = true
                currentService = nil
                inPorts = false
                continue
            }

            guard inServices else {
                continue
            }

            if !line.hasPrefix(" ") && !line.hasPrefix("\t") {
                break
            }

            let indent = line.prefix { $0 == " " }.count
            if indent == 2, !line.hasPrefix("    ") {
                let candidate = trimmed.replacingOccurrences(of: "\"", with: "")
                    .replacingOccurrences(of: "'", with: "")
                guard let colon = candidate.firstIndex(of: ":") else {
                    continue
                }

                currentService = String(candidate[..<colon])
                inPorts = false
                continue
            }

            guard let currentService else {
                continue
            }

            if trimmed == "ports:" {
                inPorts = true
                portsIndent = indent
                continue
            }

            if inPorts, indent <= portsIndent {
                inPorts = false
            }

            guard inPorts, ports[currentService] == nil,
                  let port = hostPort(from: trimmed) else {
                continue
            }
            ports[currentService] = port
        }

        return ports
    }

    private static func hostPort(from trimmedLine: String) -> Int? {
        if let publishedRange = trimmedLine.range(of: #"published:\s*"?(\d{1,5})"?"#, options: .regularExpression) {
            let value = trimmedLine[publishedRange]
                .replacingOccurrences(of: "published:", with: "")
                .replacingOccurrences(of: "\"", with: "")
                .trimmingCharacters(in: .whitespaces)
            return Int(value)
        }

        var value = trimmedLine
        if value.hasPrefix("-") {
            value = String(value.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        value = value.replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")

        let pieces = value.split(separator: ":").map(String.init)
        if pieces.count >= 2 {
            return Int(pieces[pieces.count - 2])
        }

        return Int(value)
    }

    private static func packageCommandName(for directory: URL, rootDirectory: URL, script: String) -> String {
        if directory == rootDirectory {
            return script
        }

        return "\(relativePath(from: rootDirectory, to: directory)): \(script)"
    }

    private static func packageReason(for directory: URL, rootDirectory: URL, script: String) -> String {
        if directory == rootDirectory {
            return "package.json scripts.\(script)"
        }

        return "\(relativePath(from: rootDirectory, to: directory))/package.json scripts.\(script)"
    }

    private static func relativePath(from rootDirectory: URL, to directory: URL) -> String {
        let rootPath = rootDirectory.standardizedFileURL.path
        let directoryPath = directory.standardizedFileURL.path
        guard directoryPath.hasPrefix(rootPath) else {
            return directory.lastPathComponent
        }

        let start = directoryPath.index(directoryPath.startIndex, offsetBy: rootPath.count)
        return directoryPath[start...].trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func normalizedPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func preferredPort(in script: String, packageRoot: [String: Any]?) -> Int? {
        if let explicitPort = explicitPort(in: script) {
            return explicitPort
        }

        let lowercasedScript = script.lowercased()
        if lowercasedScript.contains("next dev") || hasPackageDependency("next", in: packageRoot) {
            return 3000
        }
        if lowercasedScript.contains("vite") || hasPackageDependency("vite", in: packageRoot) {
            return 5173
        }
        if lowercasedScript.contains("astro") || hasPackageDependency("astro", in: packageRoot) {
            return 4321
        }

        return nil
    }

    private static func packageGroup(
        scriptName: String,
        scriptValue: String,
        packageRoot: [String: Any],
        directory: URL,
        rootDirectory: URL
    ) -> CommandGroup {
        let relativePath = relativePath(from: rootDirectory, to: directory).lowercased()
        let script = "\(scriptName) \(scriptValue)".lowercased()
        if relativePath.contains("worker") || script.contains("worker") || script.contains("queue") || script.contains("cron") {
            return .worker
        }
        if relativePath.contains("api") || relativePath.contains("server") || script.contains("api") || script.contains("server") {
            return .api
        }
        if relativePath.contains("frontend")
            || relativePath.contains("web")
            || script.contains("next")
            || script.contains("vite")
            || script.contains("astro")
            || hasPackageDependency("next", in: packageRoot)
            || hasPackageDependency("vite", in: packageRoot)
            || hasPackageDependency("astro", in: packageRoot)
            || hasPackageDependency("react", in: packageRoot)
            || hasPackageDependency("vue", in: packageRoot) {
            return .frontend
        }
        return .other
    }

    private static func explicitPort(in command: String) -> Int? {
        let patterns = [
            #"(?:(?:^|\s)PORT=)(\d{2,5})(?:\s|$)"#,
            #"--port[=\s]+(\d{2,5})(?:\s|$)"#,
            #"(?:(?:^|\s)-p\s+)(\d{2,5})(?:\s|$)"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }

            let range = NSRange(command.startIndex..<command.endIndex, in: command)
            guard let match = regex.firstMatch(in: command, range: range),
                  let portRange = Range(match.range(at: 1), in: command),
                  let port = Int(command[portRange]) else {
                continue
            }

            return port
        }

        return nil
    }

    private static func hasPackageDependency(_ name: String, in packageRoot: [String: Any]?) -> Bool {
        guard let packageRoot else {
            return false
        }

        for key in ["dependencies", "devDependencies"] {
            guard let dependencies = packageRoot[key] as? [String: Any],
                  dependencies[name] != nil else {
                continue
            }
            return true
        }

        return false
    }

    private static func unique(_ commands: [DevCommand]) -> [DevCommand] {
        var seen = Set<String>()
        return commands.filter { command in
            let key = "\(command.workingDirectoryPath)|\(command.display)"
            guard !seen.contains(key) else {
                return false
            }
            seen.insert(key)
            return true
        }
    }
}
