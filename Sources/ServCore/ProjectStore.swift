import Foundation

public struct Project: Codable, Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var path: String
    public var commands: [Command]

    public struct Command: Codable, Identifiable, Equatable {
        public var id: UUID
        public var name: String
        public var executable: String
        public var arguments: [String]
        public var display: String
        public var reason: String
        public var workingDirectoryPath: String
        public var preferredPort: Int?
        public var portOverrideStrategy: PortOverrideStrategy?
        public var group: CommandGroup
        public var isFavorite: Bool
        public var isHidden: Bool
        public var environment: [String: String]
        public var healthURLString: String?

        public init(_ command: DevCommand) {
            id = UUID()
            name = command.name
            executable = command.executable
            arguments = command.arguments
            display = command.display
            reason = command.reason
            workingDirectoryPath = command.workingDirectoryPath
            preferredPort = command.preferredPort
            portOverrideStrategy = command.portOverrideStrategy
            group = command.group
            isFavorite = false
            isHidden = false
            environment = command.environment
            healthURLString = command.healthURLString
        }

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case executable
            case arguments
            case display
            case reason
            case workingDirectoryPath
            case preferredPort
            case portOverrideStrategy
            case group
            case isFavorite
            case isHidden
            case environment
            case healthURLString
        }

        public var devCommand: DevCommand {
            DevCommand(
                name: name,
                executable: executable,
                arguments: arguments,
                display: display,
                reason: reason,
                workingDirectoryPath: workingDirectoryPath,
                preferredPort: preferredPort,
                portOverrideStrategy: portOverrideStrategy,
                group: group,
                environment: environment,
                healthURLString: healthURLString
            )
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            name = try container.decodeIfPresent(String.self, forKey: .name)
                ?? container.decode(String.self, forKey: .display)
            executable = try container.decode(String.self, forKey: .executable)
            arguments = try container.decode([String].self, forKey: .arguments)
            display = try container.decode(String.self, forKey: .display)
            reason = try container.decode(String.self, forKey: .reason)
            workingDirectoryPath = try container.decodeIfPresent(String.self, forKey: .workingDirectoryPath) ?? ""
            preferredPort = try container.decodeIfPresent(Int.self, forKey: .preferredPort)
            portOverrideStrategy = try container.decodeIfPresent(
                PortOverrideStrategy.self,
                forKey: .portOverrideStrategy
            )
            let decodedGroup = try container.decodeIfPresent(CommandGroup.self, forKey: .group)
            let inferredGroup = CommandGroup.infer(
                name: name,
                display: display,
                reason: reason,
                workingDirectoryPath: workingDirectoryPath,
                executable: executable,
                arguments: arguments
            )
            group = decodedGroup == .other && inferredGroup != .other
                ? inferredGroup
                : (decodedGroup ?? inferredGroup)
            isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
            isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
            environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
            healthURLString = try container.decodeIfPresent(String.self, forKey: .healthURLString)
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case path
        case command
        case commands
    }

    public init(id: UUID, name: String, path: String, commands: [Command]) {
        self.id = id
        self.name = name
        self.path = path
        self.commands = commands
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        let decodedPath = try container.decode(String.self, forKey: .path)
        path = decodedPath

        if let decodedCommands = try container.decodeIfPresent([Command].self, forKey: .commands) {
            let fixedCommands = decodedCommands.map { command in
                var fixed = command
                if fixed.workingDirectoryPath.isEmpty {
                    fixed.workingDirectoryPath = decodedPath
                }
                return fixed
            }
            commands = fixedCommands
        } else if let decodedCommand = try container.decodeIfPresent(Command.self, forKey: .command) {
            var fixed = decodedCommand
            if fixed.workingDirectoryPath.isEmpty {
                fixed.workingDirectoryPath = decodedPath
            }
            commands = [fixed]
        } else {
            commands = []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(path, forKey: .path)
        try container.encode(commands, forKey: .commands)
    }
}

public final class ProjectStore {
    private let fileURL: URL
    public private(set) var projects: [Project] = []

    public init(fileManager: FileManager = .default) {
        let supportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Serv", isDirectory: true)
        try? fileManager.createDirectory(at: supportURL, withIntermediateDirectories: true)
        fileURL = supportURL.appendingPathComponent("projects.json")
        load()
    }

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        try? fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        load()
    }

    public func upsert(project: Project) {
        if let index = projects.firstIndex(where: { $0.path == project.path }) {
            var updated = project
            updated.commands = updated.commands.map { command in
                guard let existing = projects[index].commands.first(where: { sameCommand($0, command) }) else {
                    return command
                }

                var preserved = command
                preserved.id = existing.id
                preserved.group = existing.group
                preserved.isFavorite = existing.isFavorite
                preserved.isHidden = existing.isHidden
                preserved.environment = existing.environment
                preserved.healthURLString = existing.healthURLString
                return preserved
            }

            let customCommands = projects[index].commands.filter { $0.reason == "Custom command" }
            for command in customCommands where !updated.commands.contains(where: { sameCommand($0, command) }) {
                updated.commands.append(command)
            }
            projects[index] = updated
        } else {
            projects.append(project)
        }
        projects.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        save()
    }

    public func upsert(command: Project.Command, in projectID: UUID) {
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }) else {
            return
        }

        if let commandIndex = projects[projectIndex].commands.firstIndex(where: { $0.id == command.id }) {
            projects[projectIndex].commands[commandIndex] = command
        } else {
            projects[projectIndex].commands.append(command)
        }
        save()
    }

    public func remove(commandID: UUID, from projectID: UUID) {
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }) else {
            return
        }

        projects[projectIndex].commands.removeAll { $0.id == commandID }
        save()
    }

    public func remove(projectID: UUID) {
        projects.removeAll { $0.id == projectID }
        save()
    }

    private func load() {
        guard
            let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode([Project].self, from: data)
        else {
            projects = []
            return
        }
        projects = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(projects) else {
            return
        }
        try? data.write(to: fileURL, options: [.atomic])
    }

    private func sameCommand(_ lhs: Project.Command, _ rhs: Project.Command) -> Bool {
        lhs.display == rhs.display && lhs.workingDirectoryPath == rhs.workingDirectoryPath
    }
}
