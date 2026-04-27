import XCTest
@testable import ServCore

final class DevCommandDetectorTests: XCTestCase {
    func testDetectsPnpmDevScriptWhenLockfileExists() throws {
        let directory = try makeTemporaryDirectory()
        try write(
            """
            {"scripts":{"start":"next start","dev":"next dev"}}
            """,
            to: directory.appendingPathComponent("package.json")
        )
        try write("", to: directory.appendingPathComponent("pnpm-lock.yaml"))

        let command = DevCommandDetector.detect(in: directory)

        XCTAssertEqual(command?.name, "dev")
        XCTAssertEqual(command?.executable, "pnpm")
        XCTAssertEqual(command?.arguments, ["run", "dev"])
        XCTAssertEqual(command?.display, "pnpm run dev")
        XCTAssertEqual(command?.reason, "package.json scripts.dev")
        XCTAssertEqual(command?.workingDirectoryPath, directory.path)
        XCTAssertEqual(command?.preferredPort, 3000)
        XCTAssertEqual(command?.portOverrideStrategy, .appendFlag)
        XCTAssertEqual(command?.group, .frontend)
    }

    func testFallsBackToStartScriptWhenDevIsMissing() throws {
        let directory = try makeTemporaryDirectory()
        try write(
            """
            {"scripts":{"start":"vite --host 0.0.0.0"}}
            """,
            to: directory.appendingPathComponent("package.json")
        )

        let command = DevCommandDetector.detect(in: directory)

        XCTAssertEqual(command?.executable, "npm")
        XCTAssertEqual(command?.arguments, ["run", "start"])
        XCTAssertEqual(command?.display, "npm run start")
        XCTAssertEqual(command?.preferredPort, 5173)
    }

    func testClassifiesGenericPackageDevCommandAsFrontend() throws {
        let command = CommandGroup.infer(
            name: "dev",
            display: "pnpm run dev",
            reason: "package.json scripts.dev",
            workingDirectoryPath: "/tmp/app",
            executable: "pnpm",
            arguments: ["run", "dev"]
        )

        XCTAssertEqual(command, .frontend)
    }

    func testDetectsYarnScriptSyntax() throws {
        let directory = try makeTemporaryDirectory()
        try write(
            """
            {"scripts":{"serve":"astro dev"}}
            """,
            to: directory.appendingPathComponent("package.json")
        )
        try write("", to: directory.appendingPathComponent("yarn.lock"))

        let command = DevCommandDetector.detect(in: directory)

        XCTAssertEqual(command?.executable, "yarn")
        XCTAssertEqual(command?.arguments, ["serve"])
        XCTAssertEqual(command?.display, "yarn serve")
        XCTAssertEqual(command?.preferredPort, 4321)
    }

    func testDetectsMakefileTargetWhenPackageJsonIsAbsent() throws {
        let directory = try makeTemporaryDirectory()
        try write(
            """
            build:
            \techo build

            dev:
            \tpython -m http.server
            """,
            to: directory.appendingPathComponent("Makefile")
        )

        let command = DevCommandDetector.detect(in: directory)

        XCTAssertEqual(command?.executable, "make")
        XCTAssertEqual(command?.arguments, ["dev"])
        XCTAssertEqual(command?.display, "make dev")
        XCTAssertEqual(command?.reason, "Makefile target dev")
    }

    func testReturnsNilWhenNoKnownCommandExists() throws {
        let directory = try makeTemporaryDirectory()
        try write("{}", to: directory.appendingPathComponent("package.json"))

        XCTAssertNil(DevCommandDetector.detect(in: directory))
    }

    func testDetectsDockerComposeCommandsAndServices() throws {
        let directory = try makeTemporaryDirectory()
        try write(
            """
            services:
              proxy:
                image: nginx
                ports:
                  - "8080:80"
              screener:
                image: node
              worker:
                image: node
                ports:
                  - "5174:5173"
            volumes:
              db:
            """,
            to: directory.appendingPathComponent("docker-compose.yml")
        )

        let commands = DevCommandDetector.detectAll(in: directory)

        XCTAssertTrue(commands.contains { $0.name == "All services" && $0.display == "docker compose up" })
        XCTAssertTrue(commands.contains { $0.name == "Screener + proxy" && $0.display == "docker compose up screener proxy" })
        XCTAssertTrue(commands.contains { $0.name == "worker" && $0.display == "docker compose up worker" })
        XCTAssertNil(commands.first { $0.name == "All services" }?.preferredPort)
        XCTAssertEqual(commands.first { $0.name == "proxy" }?.preferredPort, 8080)
        XCTAssertEqual(commands.first { $0.name == "worker" }?.preferredPort, 5174)
        XCTAssertEqual(commands.first { $0.name == "worker" }?.group, .compose)
    }

    func testDetectsNestedPackageCommands() throws {
        let directory = try makeTemporaryDirectory()
        let frontend = directory.appendingPathComponent("services/frontend/admin", isDirectory: true)
        try FileManager.default.createDirectory(at: frontend, withIntermediateDirectories: true)
        try write(
            """
            {"scripts":{"dev":"next dev"}}
            """,
            to: frontend.appendingPathComponent("package.json")
        )

        let commands = DevCommandDetector.detectAll(in: directory)

        XCTAssertEqual(commands.first?.name, "services/frontend/admin: dev")
        XCTAssertEqual(commands.first?.display, "npm run dev")
        XCTAssertEqual(commands.first?.workingDirectoryPath, frontend.path)
        XCTAssertEqual(commands.first?.preferredPort, 3000)
    }

    func testBuildsShellBackedCustomCommand() throws {
        let directory = try makeTemporaryDirectory()

        let command = DevCommandDetector.shellCommand(
            name: "Local stack",
            commandLine: "docker compose up screener proxy",
            workingDirectory: directory
        )

        XCTAssertEqual(command.name, "Local stack")
        XCTAssertEqual(command.executable, "/bin/zsh")
        XCTAssertEqual(command.arguments, ["-lc", "docker compose up screener proxy"])
        XCTAssertEqual(command.display, "docker compose up screener proxy")
        XCTAssertEqual(command.reason, "Custom command")
        XCTAssertEqual(command.workingDirectoryPath, directory.path)
        XCTAssertNil(command.preferredPort)
        XCTAssertNil(command.portOverrideStrategy)
        XCTAssertEqual(command.group, .custom)
    }

    func testDetectsExplicitPortFromPackageScript() throws {
        let directory = try makeTemporaryDirectory()
        try write(
            """
            {"scripts":{"dev":"vite --host 127.0.0.1 --port 5174"}}
            """,
            to: directory.appendingPathComponent("package.json")
        )

        let command = DevCommandDetector.detect(in: directory)

        XCTAssertEqual(command?.preferredPort, 5174)
    }

    func testDetectsPortFromCustomCommand() throws {
        let directory = try makeTemporaryDirectory()

        let command = DevCommandDetector.shellCommand(
            name: "Preview",
            commandLine: "npm run dev -- --port=4000",
            workingDirectory: directory
        )

        XCTAssertEqual(command.preferredPort, 4000)
        XCTAssertEqual(command.portOverrideStrategy, .replaceInShellCommand)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
