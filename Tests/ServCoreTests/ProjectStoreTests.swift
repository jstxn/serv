import XCTest
@testable import ServCore

final class ProjectStoreTests: XCTestCase {
    func testRefreshPreservesCommandIDsForRediscoveredCommands() throws {
        let store = try makeStore()
        let projectID = UUID()
        let original = Project.Command(
            DevCommand(
                name: "dev",
                executable: "npm",
                arguments: ["run", "dev"],
                display: "npm run dev",
                reason: "package.json scripts.dev",
                workingDirectoryPath: "/tmp/app",
                preferredPort: 3000,
                portOverrideStrategy: .appendFlag
            )
        )

        store.upsert(project: Project(id: projectID, name: "app", path: "/tmp/app", commands: [original]))
        var saved = try XCTUnwrap(store.projects.first?.commands.first)
        saved.isFavorite = true
        saved.isHidden = true
        saved.group = .api
        saved.environment = ["PORT": "3001"]
        saved.healthURLString = "http://localhost:3001/health"
        store.upsert(command: saved, in: projectID)

        let refreshed = Project.Command(
            DevCommand(
                name: "dev",
                executable: "npm",
                arguments: ["run", "dev"],
                display: "npm run dev",
                reason: "package.json scripts.dev",
                workingDirectoryPath: "/tmp/app",
                preferredPort: 3000,
                portOverrideStrategy: .appendFlag
            )
        )
        store.upsert(project: Project(id: projectID, name: "app", path: "/tmp/app", commands: [refreshed]))

        let command = try XCTUnwrap(store.projects.first?.commands.first)
        XCTAssertEqual(command.id, original.id)
        XCTAssertTrue(command.isFavorite)
        XCTAssertTrue(command.isHidden)
        XCTAssertEqual(command.group, .api)
        XCTAssertEqual(command.environment, ["PORT": "3001"])
        XCTAssertEqual(command.healthURLString, "http://localhost:3001/health")
    }

    func testRefreshPreservesCustomCommands() throws {
        let store = try makeStore()
        let projectID = UUID()
        let detected = Project.Command(
            DevCommand(
                name: "dev",
                executable: "npm",
                arguments: ["run", "dev"],
                display: "npm run dev",
                reason: "package.json scripts.dev",
                workingDirectoryPath: "/tmp/app"
            )
        )
        let custom = Project.Command(
            DevCommandDetector.shellCommand(
                name: "Docs",
                commandLine: "npm run docs -- --port 4000",
                workingDirectory: URL(fileURLWithPath: "/tmp/app", isDirectory: true)
            )
        )

        store.upsert(project: Project(id: projectID, name: "app", path: "/tmp/app", commands: [detected, custom]))
        store.upsert(project: Project(id: projectID, name: "app", path: "/tmp/app", commands: [detected]))

        XCTAssertTrue(store.projects.first?.commands.contains { $0.id == custom.id } == true)
    }

    func testDecodingMigratesDefaultOtherPackageDevCommandToFrontend() throws {
        let json = """
        [
          {
            "id": "\(UUID().uuidString)",
            "name": "app",
            "path": "/tmp/app",
            "commands": [
              {
                "id": "\(UUID().uuidString)",
                "name": "dev",
                "executable": "pnpm",
                "arguments": ["run", "dev"],
                "display": "pnpm run dev",
                "reason": "package.json scripts.dev",
                "workingDirectoryPath": "/tmp/app",
                "group": "Other"
              }
            ]
          }
        ]
        """
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("projects.json")
        try json.write(to: url, atomically: true, encoding: .utf8)

        let store = ProjectStore(fileURL: url)

        XCTAssertEqual(store.projects.first?.commands.first?.group, .frontend)
    }

    private func makeStore() throws -> ProjectStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return ProjectStore(fileURL: directory.appendingPathComponent("projects.json"))
    }
}
