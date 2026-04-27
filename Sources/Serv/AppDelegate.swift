import AppKit
import ServCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store = ProjectStore()
    private let processController = ProcessController()
    private let menu = NSMenu()
    private var lastStatus = "Ready"
    private var portStatusCache: [Int: Bool] = [:]
    private var portChecksInFlight = Set<Int>()
    private var composeStatusCache: [String: Set<String>] = [:]
    private var composeChecksInFlight = Set<String>()
    private var managementWindowController: ManagementWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        processController.onStateChange = { [weak self] in
            self?.rebuildMenu()
        }
        configureStatusItem()
        rebuildMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        processController.stopAll()
    }

    private func configureStatusItem() {
        statusItem.button?.image = NSImage(
            systemSymbolName: "play.rectangle.on.rectangle",
            accessibilityDescription: "Serv"
        )
        statusItem.button?.imagePosition = .imageLeading
        statusItem.menu = menu
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let title = NSMenuItem(title: "Serv", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        if !lastStatus.isEmpty {
            let status = NSMenuItem(title: lastStatus, action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
        }

        menu.addItem(.separator())

        let addItem = NSMenuItem(title: "Add Project...", action: #selector(addProject), keyEquivalent: "o")
        addItem.target = self
        menu.addItem(addItem)

        let manageItem = NSMenuItem(title: "Manage Projects...", action: #selector(showManagementWindow), keyEquivalent: "")
        manageItem.target = self
        manageItem.isEnabled = !store.projects.isEmpty
        menu.addItem(manageItem)

        if store.projects.isEmpty {
            let empty = NSMenuItem(title: "No projects added", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            menu.addItem(.separator())
            for project in store.projects {
                addProjectMenu(project)
            }
        }

        menu.addItem(.separator())

        let stopAllItem = NSMenuItem(title: "Stop All", action: #selector(stopAll), keyEquivalent: "")
        stopAllItem.target = self
        menu.addItem(stopAllItem)

        let quitItem = NSMenuItem(title: "Quit Serv", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func addProjectMenu(_ project: Project) {
        let submenu = NSMenu()

        let pathItem = NSMenuItem(title: project.path, action: nil, keyEquivalent: "")
        pathItem.isEnabled = false
        submenu.addItem(pathItem)

        let hiddenCount = project.commands.filter(\.isHidden).count
        let countSuffix = hiddenCount > 0 ? ", \(hiddenCount) hidden" : ""
        let countItem = NSMenuItem(title: "\(project.commands.count) command profiles\(countSuffix)", action: nil, keyEquivalent: "")
        countItem.isEnabled = false
        submenu.addItem(countItem)

        let revealItem = NSMenuItem(title: "Reveal in Finder", action: #selector(revealProject(_:)), keyEquivalent: "")
        revealItem.target = self
        revealItem.representedObject = project.id
        submenu.addItem(revealItem)

        let addCustomItem = NSMenuItem(title: "Add Custom Command...", action: #selector(addCustomCommand(_:)), keyEquivalent: "")
        addCustomItem.target = self
        addCustomItem.representedObject = project.id
        submenu.addItem(addCustomItem)

        let refreshItem = NSMenuItem(title: "Refresh Commands", action: #selector(refreshProject(_:)), keyEquivalent: "")
        refreshItem.target = self
        refreshItem.representedObject = project.id
        submenu.addItem(refreshItem)

        let manageItem = NSMenuItem(title: "Manage Project...", action: #selector(showProjectManagementWindow(_:)), keyEquivalent: "")
        manageItem.target = self
        manageItem.representedObject = project.id
        submenu.addItem(manageItem)

        submenu.addItem(.separator())

        let visibleCommands = project.commands.filter { !$0.isHidden }
        let favorites = visibleCommands.filter(\.isFavorite)
        if !favorites.isEmpty {
            addSectionHeader("Favorites", to: submenu)
            for command in favorites {
                addCommandMenu(project: project, command: command, to: submenu)
            }
        }

        for group in CommandGroup.allCases {
            let commands = visibleCommands
                .filter { displayGroup(for: $0) == group && !$0.isFavorite }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            guard !commands.isEmpty else {
                continue
            }

            addSectionHeader(group.rawValue, to: submenu)
            for command in commands {
                addCommandMenu(project: project, command: command, to: submenu)
            }
        }

        if visibleCommands.isEmpty {
            let emptyItem = NSMenuItem(title: "All profiles hidden", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            submenu.addItem(emptyItem)
        }

        submenu.addItem(.separator())

        let removeItem = NSMenuItem(title: "Remove Project", action: #selector(removeProject(_:)), keyEquivalent: "")
        removeItem.target = self
        removeItem.representedObject = project.id
        submenu.addItem(removeItem)

        let projectItem = NSMenuItem(title: project.name, action: nil, keyEquivalent: "")
        projectItem.submenu = submenu
        menu.addItem(projectItem)
    }

    private func addCommandMenu(project: Project, command: Project.Command, to menu: NSMenu) {
        let state = commandMenuState(for: project, command: command)
        let submenu = NSMenu()

        let commandItem = NSMenuItem(title: command.display, action: nil, keyEquivalent: "")
        commandItem.isEnabled = false
        submenu.addItem(commandItem)

        let directoryItem = NSMenuItem(title: command.workingDirectoryPath, action: nil, keyEquivalent: "")
        directoryItem.isEnabled = false
        submenu.addItem(directoryItem)

        let reasonItem = NSMenuItem(title: command.reason, action: nil, keyEquivalent: "")
        reasonItem.isEnabled = false
        submenu.addItem(reasonItem)

        let groupItem = NSMenuItem(title: "\(displayGroup(for: command).rawValue) profile", action: nil, keyEquivalent: "")
        groupItem.isEnabled = false
        submenu.addItem(groupItem)

        let statusItem = NSMenuItem(title: state.status, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        submenu.addItem(statusItem)

        if let lastErrorPreview = state.lastErrorPreview {
            let errorItem = NSMenuItem(title: "Last error: \(lastErrorPreview)", action: nil, keyEquivalent: "")
            errorItem.isEnabled = false
            submenu.addItem(errorItem)
        }

        submenu.addItem(.separator())

        let selection = CommandSelection(projectID: project.id, commandID: command.id)
        let toggleTitle = state.isRunning ? "Stop" : (state.externalStopTitle ?? "Start")
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(toggleCommand(_:)), keyEquivalent: "")
        toggleItem.target = self
        toggleItem.representedObject = selection
        submenu.addItem(toggleItem)

        let urlTitle = state.port.map { "Open http://localhost:\($0)" } ?? "Open Local URL"
        let openURLItem = NSMenuItem(title: urlTitle, action: #selector(openLocalURL(_:)), keyEquivalent: "")
        openURLItem.target = self
        openURLItem.representedObject = selection
        openURLItem.isEnabled = state.localURL != nil && (state.isRunning || state.isExternal)
        submenu.addItem(openURLItem)

        let logsItem = NSMenuItem(title: "Watch Logs in Terminal", action: #selector(watchLogs(_:)), keyEquivalent: "")
        logsItem.target = self
        logsItem.representedObject = selection
        submenu.addItem(logsItem)

        let favoriteTitle = command.isFavorite ? "Unpin Favorite" : "Pin Favorite"
        let favoriteItem = NSMenuItem(title: favoriteTitle, action: #selector(toggleFavorite(_:)), keyEquivalent: "")
        favoriteItem.target = self
        favoriteItem.representedObject = selection
        submenu.addItem(favoriteItem)

        let hideItem = NSMenuItem(title: "Hide Command", action: #selector(hideCommand(_:)), keyEquivalent: "")
        hideItem.target = self
        hideItem.representedObject = selection
        submenu.addItem(hideItem)

        let editItem = NSMenuItem(title: "Edit Profile...", action: #selector(editCommandProfile(_:)), keyEquivalent: "")
        editItem.target = self
        editItem.representedObject = selection
        submenu.addItem(editItem)

        let removeItem = NSMenuItem(title: "Remove Command", action: #selector(removeCommand(_:)), keyEquivalent: "")
        removeItem.target = self
        removeItem.representedObject = selection
        submenu.addItem(removeItem)

        let statusPrefix = state.isRunning ? "Stop" : (state.isExternal ? "Stop" : "Start")
        let commandMenuItem = NSMenuItem(title: "\(statusPrefix) \(command.name)", action: nil, keyEquivalent: "")
        commandMenuItem.image = StatusIconFactory.icon(for: state.indicator)
        commandMenuItem.submenu = submenu
        menu.addItem(commandMenuItem)
    }

    private func addSectionHeader(_ title: String, to menu: NSMenu) {
        if menu.items.last?.isSeparatorItem == false {
            menu.addItem(.separator())
        }

        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func displayGroup(for command: Project.Command) -> CommandGroup {
        let inferredGroup = CommandGroup.infer(
            name: command.name,
            display: command.display,
            reason: command.reason,
            workingDirectoryPath: command.workingDirectoryPath,
            executable: command.executable,
            arguments: command.arguments
        )
        return command.group == .other && inferredGroup != .other ? inferredGroup : command.group
    }

    @objc private func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Select a project directory"

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        let detectedCommands = DevCommandDetector.detectAll(in: url)
        let commands: [Project.Command]
        if detectedCommands.isEmpty {
            guard let customCommand = promptForCustomCommand(projectName: url.lastPathComponent, directory: url) else {
                showAlert(
                    title: "No dev command found",
                    message: "Serv can save a custom command, or detect package.json scripts, Makefile targets, and Docker Compose projects."
                )
                return
            }
            commands = [Project.Command(customCommand)]
        } else {
            commands = detectedCommands.map(Project.Command.init)
        }

        let project = Project(
            id: store.projects.first(where: { $0.path == url.path })?.id ?? UUID(),
            name: url.lastPathComponent,
            path: url.path,
            commands: commands
        )
        store.upsert(project: project)
        lastStatus = "Added \(project.name): \(commands.count) commands"
        rebuildMenu()
    }

    @objc private func addCustomCommand(_ sender: NSMenuItem) {
        guard let project = project(from: sender),
              let customCommand = promptForCustomCommand(
                projectName: project.name,
                directory: URL(fileURLWithPath: project.path, isDirectory: true)
              ) else {
            return
        }

        let command = Project.Command(customCommand)
        store.upsert(command: command, in: project.id)
        lastStatus = "Added \(command.name)"
        rebuildMenu()
    }

    @objc private func refreshProject(_ sender: NSMenuItem) {
        guard let project = project(from: sender) else {
            return
        }

        let refreshedCommands = DevCommandDetector.detectAll(
            in: URL(fileURLWithPath: project.path, isDirectory: true)
        )
        let customCommands = project.commands.filter { $0.reason == "Custom command" }
        let commands = refreshedCommands.map(Project.Command.init) + customCommands

        guard !commands.isEmpty else {
            showAlert(
                title: "No commands found",
                message: "Serv did not find package.json scripts, Makefile targets, Docker Compose services, or saved custom commands for this project."
            )
            return
        }

        store.upsert(
            project: Project(
                id: project.id,
                name: project.name,
                path: project.path,
                commands: commands
            )
        )
        lastStatus = "Refreshed \(project.name)"
        rebuildMenu()
    }

    @objc private func toggleCommand(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? CommandSelection,
              let project = store.projects.first(where: { $0.id == selection.projectID }),
              let command = project.commands.first(where: { $0.id == selection.commandID }) else {
            return
        }

        let menuState = commandMenuState(for: project, command: command)
        if menuState.isExternal {
            stopExternal(project: project, command: command, state: menuState)
            return
        }

        let state = processController.state(for: project, command: command)
        let portOverride: Int?
        if state.isRunning {
            portOverride = nil
        } else {
            switch startPortChoice(for: command) {
            case .start(let alternatePort):
                portOverride = alternatePort
            case .cancel:
                rebuildMenu()
                return
            }
        }

        lastStatus = processController.toggle(project: project, command: command, portOverride: portOverride)
        rebuildMenu()
    }

    @objc private func openLocalURL(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? CommandSelection,
              let project = store.projects.first(where: { $0.id == selection.projectID }),
              let command = project.commands.first(where: { $0.id == selection.commandID }),
              let url = commandMenuState(for: project, command: command).localURL else {
            return
        }

        NSWorkspace.shared.open(url)
        lastStatus = "Opened \(url.absoluteString)"
        rebuildMenu()
    }

    @objc private func watchLogs(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? CommandSelection,
              let project = store.projects.first(where: { $0.id == selection.projectID }),
              let command = project.commands.first(where: { $0.id == selection.commandID }) else {
            return
        }

        openLogInTerminal(project: project, command: command)
        rebuildMenu()
    }

    @objc private func toggleFavorite(_ sender: NSMenuItem) {
        guard var command = selectedCommand(from: sender) else {
            return
        }

        command.value.isFavorite.toggle()
        store.upsert(command: command.value, in: command.project.id)
        lastStatus = command.value.isFavorite ? "Pinned \(command.value.name)" : "Unpinned \(command.value.name)"
        rebuildMenu()
    }

    @objc private func hideCommand(_ sender: NSMenuItem) {
        guard var command = selectedCommand(from: sender) else {
            return
        }

        command.value.isHidden = true
        store.upsert(command: command.value, in: command.project.id)
        lastStatus = "Hidden \(command.value.name)"
        rebuildMenu()
    }

    @objc private func editCommandProfile(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? CommandSelection else {
            return
        }

        presentManagementWindow(projectID: selection.projectID, commandID: selection.commandID)
    }

    @objc private func showManagementWindow() {
        presentManagementWindow(projectID: nil, commandID: nil)
    }

    @objc private func showProjectManagementWindow(_ sender: NSMenuItem) {
        guard let project = project(from: sender) else {
            return
        }
        presentManagementWindow(projectID: project.id, commandID: nil)
    }

    private func stopExternal(project: Project, command: Project.Command, state: CommandMenuState) {
        if let services = composeServices(for: command) {
            stopExternalCompose(project: project, command: command, services: services)
            return
        }

        guard let port = state.port else {
            return
        }
        stopExternalPortListener(command: command, port: port)
    }

    private func stopExternalCompose(project: Project, command: Project.Command, services: [String]) {
        let serviceText = services.isEmpty ? "all compose services" : services.joined(separator: ", ")
        guard confirmComposeStop(project: project, command: command, services: services) else {
            return
        }

        lastStatus = "Stopping \(serviceText)"
        rebuildMenu()

        let workingDirectoryPath = command.workingDirectoryPath
        Task { [weak self] in
            let result = await Task.detached {
                ComposeRuntime.stop(in: workingDirectoryPath, services: services)
            }.value

            guard let self else {
                return
            }
            self.composeStatusCache[workingDirectoryPath] = nil
            self.portStatusCache.removeAll()
            self.lastStatus = result ? "Stopped \(serviceText)" : "Failed to stop \(serviceText)"
            self.rebuildMenu()
        }
    }

    private func stopExternalPortListener(command: Project.Command, port: Int) {
        let pids = PortInspector.listeningPIDs(on: port)
        guard !pids.isEmpty else {
            portStatusCache[port] = false
            lastStatus = "No listener on port \(port)"
            rebuildMenu()
            return
        }

        let processDetails = PortInspector.processCommandLines(for: pids)
        guard confirmExternalStop(command: command, port: port, pids: pids, processDetails: processDetails) else {
            return
        }

        for pid in pids {
            processController.terminateExternalProcessTree(rootPID: pid)
        }
        portStatusCache[port] = false
        lastStatus = "Stopped external port \(port)"
        rebuildMenu()
    }

    @objc private func removeCommand(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? CommandSelection,
              let project = store.projects.first(where: { $0.id == selection.projectID }),
              let command = project.commands.first(where: { $0.id == selection.commandID }) else {
            return
        }

        processController.stop(project: project, command: command)
        store.remove(commandID: command.id, from: project.id)
        lastStatus = "Removed \(command.name)"
        rebuildMenu()
    }

    @objc private func revealProject(_ sender: NSMenuItem) {
        guard let project = project(from: sender) else {
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.path)])
    }

    @objc private func removeProject(_ sender: NSMenuItem) {
        guard let project = project(from: sender) else {
            return
        }

        processController.stop(project: project)
        store.remove(projectID: project.id)
        lastStatus = "Removed \(project.name)"
        rebuildMenu()
    }

    @objc private func stopAll() {
        processController.stopAll()
        lastStatus = "Stopped all"
        rebuildMenu()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func promptForCustomCommand(projectName: String, directory: URL) -> DevCommand? {
        let alert = NSAlert()
        alert.messageText = "Add custom command"
        alert.informativeText = "Save a command to run from \(directory.path)."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8

        let nameField = NSTextField(string: "Custom")
        nameField.placeholderString = "Name"

        let commandField = NSTextField(string: "")
        commandField.placeholderString = "docker compose up"
        commandField.cell?.wraps = false

        stack.addArrangedSubview(nameField)
        stack.addArrangedSubview(commandField)
        NSLayoutConstraint.activate([
            nameField.widthAnchor.constraint(equalToConstant: 320),
            commandField.widthAnchor.constraint(equalToConstant: 320)
        ])
        alert.accessoryView = stack

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }

        let commandLine = commandField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !commandLine.isEmpty else {
            return nil
        }

        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return DevCommandDetector.shellCommand(
            name: name.isEmpty ? projectName : name,
            commandLine: commandLine,
            workingDirectory: directory
        )
    }

    private func openLogInTerminal(project: Project, command: Project.Command) {
        let logURL = processController.ensureLogFile(for: project, command: command)
        let tailCommand = "tail -n 200 -f \(shellQuote(logURL.path))"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e", "tell application \"Terminal\"",
            "-e", "activate",
            "-e", "do script \"\(appleScriptString(tailCommand))\"",
            "-e", "end tell"
        ]

        do {
            try process.run()
            lastStatus = "Watching logs for \(command.name)"
        } catch {
            lastStatus = "Failed to open logs"
            showAlert(title: "Could not open Terminal", message: error.localizedDescription)
        }
    }

    private func startPortChoice(for command: Project.Command) -> StartPortChoice {
        guard let preferredPort = preferredPort(for: command) else {
            return .start(nil)
        }

        guard PortInspector.isPortTakenNow(preferredPort) else {
            return .start(nil)
        }

        let suggestedPort = nextAvailablePort(after: preferredPort)
        guard let alternatePort = promptForAlternatePort(
            command: command,
            occupiedPort: preferredPort,
            suggestedPort: suggestedPort
        ) else {
            return .cancel
        }

        if PortInspector.isPortTakenNow(alternatePort) {
            showAlert(
                title: "Port is still in use",
                message: "Port \(alternatePort) is already listening. Choose another port and start again."
            )
            return .cancel
        }

        return .start(alternatePort)
    }

    private func preferredPort(for command: Project.Command) -> Int? {
        if let preferredPort = command.preferredPort {
            return preferredPort
        }

        let workingDirectory = URL(fileURLWithPath: command.workingDirectoryPath, isDirectory: true)
        return DevCommandDetector.detectAll(in: workingDirectory)
            .first { detectedCommand in
                detectedCommand.display == command.display || detectedCommand.name == command.name
            }?
            .preferredPort
    }

    private func composeCommandIsRunning(_ command: Project.Command) -> Bool {
        guard let services = composeServices(for: command) else {
            return false
        }

        guard let runningServices = cachedComposeRunningServices(for: command.workingDirectoryPath) else {
            return false
        }

        if services.isEmpty {
            return !runningServices.isEmpty
        }

        return services.contains { runningServices.contains($0) }
    }

    private func composeServices(for command: Project.Command) -> [String]? {
        guard command.executable == "docker",
              command.arguments.count >= 2,
              command.arguments[0] == "compose",
              command.arguments[1] == "up" else {
            return nil
        }

        return Array(command.arguments.dropFirst(2))
    }

    private func cachedComposeRunningServices(for workingDirectoryPath: String) -> Set<String>? {
        if let cached = composeStatusCache[workingDirectoryPath] {
            return cached
        }

        scheduleComposeCheck(workingDirectoryPath)
        return nil
    }

    private func scheduleComposeCheck(_ workingDirectoryPath: String) {
        guard !composeChecksInFlight.contains(workingDirectoryPath) else {
            return
        }

        composeChecksInFlight.insert(workingDirectoryPath)
        Task { [weak self] in
            let services = await Task.detached {
                ComposeRuntime.runningServices(in: workingDirectoryPath)
            }.value
            guard let self else {
                return
            }
            self.composeStatusCache[workingDirectoryPath] = services
            self.composeChecksInFlight.remove(workingDirectoryPath)
            self.rebuildMenu()
        }
    }

    private func commandMenuState(for project: Project, command: Project.Command) -> CommandMenuState {
        guard FileManager.default.fileExists(atPath: command.workingDirectoryPath) else {
            return CommandMenuState(
                status: "Missing working directory",
                isRunning: false,
                isExternal: false,
                port: command.preferredPort,
                indicator: .problem,
                externalStopTitle: nil,
                lastErrorPreview: nil
            )
        }

        let processState = processController.state(for: project, command: command)
        if processState.isRunning {
            let port = processController.runningPort(for: project, command: command) ?? preferredPort(for: command)
            if let port {
                return CommandMenuState(
                    status: processState.status,
                    isRunning: true,
                    isExternal: false,
                    port: port,
                    indicator: processState.phase == .starting ? .starting : .running,
                    externalStopTitle: nil,
                    lastErrorPreview: processState.lastErrorPreview
                )
            }
            return CommandMenuState(
                status: processState.status,
                isRunning: true,
                isExternal: false,
                port: nil,
                indicator: processState.phase == .starting ? .starting : .running,
                externalStopTitle: nil,
                lastErrorPreview: processState.lastErrorPreview
            )
        }

        if processState.phase == .failed || processState.phase == .exited {
            return CommandMenuState(
                status: processState.status,
                isRunning: false,
                isExternal: false,
                port: preferredPort(for: command),
                indicator: processState.phase == .failed ? .problem : .stopped,
                externalStopTitle: nil,
                lastErrorPreview: processState.lastErrorPreview
            )
        }

        if composeCommandIsRunning(command) {
            return CommandMenuState(
                status: "Running externally via Docker Compose",
                isRunning: false,
                isExternal: true,
                port: preferredPort(for: command),
                indicator: .external,
                externalStopTitle: "Stop External",
                lastErrorPreview: processState.lastErrorPreview
            )
        }

        guard let port = preferredPort(for: command) else {
            return CommandMenuState(
                status: "Stopped",
                isRunning: false,
                isExternal: false,
                port: nil,
                indicator: .stopped,
                externalStopTitle: nil,
                lastErrorPreview: processState.lastErrorPreview
            )
        }

        if cachedPortTaken(port) == true {
            return CommandMenuState(
                status: "Running externally on port \(port)",
                isRunning: false,
                isExternal: true,
                port: port,
                indicator: .external,
                externalStopTitle: "Stop External",
                lastErrorPreview: processState.lastErrorPreview
            )
        }

        return CommandMenuState(
            status: cachedPortTaken(port) == nil ? "Stopped, checking port \(port)" : "Stopped, port \(port) available",
            isRunning: false,
            isExternal: false,
            port: port,
            indicator: .stopped,
            externalStopTitle: nil,
            lastErrorPreview: processState.lastErrorPreview
        )
    }

    private func promptForAlternatePort(
        command: Project.Command,
        occupiedPort: Int,
        suggestedPort: Int
    ) -> Int? {
        let alert = NSAlert()
        alert.messageText = "Port \(occupiedPort) is already in use"
        alert.informativeText = "Use a different port for \(command.name)?"
        alert.addButton(withTitle: "Use Port")
        alert.addButton(withTitle: "Cancel")

        let portField = NSTextField(string: "\(suggestedPort)")
        portField.placeholderString = "Port"
        portField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        alert.accessoryView = portField

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn,
              let port = Int(portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...65535).contains(port) else {
            return nil
        }

        return port
    }

    private func nextAvailablePort(after port: Int) -> Int {
        for candidate in (port + 1)...min(port + 50, 65535) where !PortInspector.isPortTakenNow(candidate) {
            return candidate
        }
        return port
    }

    private func cachedPortTaken(_ port: Int) -> Bool? {
        if let cached = portStatusCache[port] {
            return cached
        }

        schedulePortCheck(port)
        return nil
    }

    private func schedulePortCheck(_ port: Int) {
        guard !portChecksInFlight.contains(port) else {
            return
        }

        portChecksInFlight.insert(port)
        Task { [weak self] in
            let isTaken = await Task.detached {
                PortInspector.isPortTakenNow(port)
            }.value
            guard let self else {
                return
            }
            self.portStatusCache[port] = isTaken
            self.portChecksInFlight.remove(port)
            self.rebuildMenu()
        }
    }

    private func confirmComposeStop(project: Project, command: Project.Command, services: [String]) -> Bool {
        let serviceText = services.isEmpty ? "all compose services" : services.joined(separator: ", ")
        let alert = NSAlert()
        alert.messageText = "Stop external Docker Compose services?"
        alert.informativeText = """
        Project: \(project.name)
        Directory: \(command.workingDirectoryPath)
        Services: \(serviceText)

        Serv will run docker compose stop from this project directory.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Stop")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmExternalStop(
        command: Project.Command,
        port: Int,
        pids: [Int32],
        processDetails: [Int32: String]
    ) -> Bool {
        let details = pids
            .map { pid in
                let commandLine = processDetails[pid] ?? "unknown command"
                return "PID \(pid): \(commandLine)"
            }
            .joined(separator: "\n")

        let alert = NSAlert()
        alert.messageText = "Stop external server?"
        alert.informativeText = """
        \(command.name) appears to be listening on port \(port) outside Serv.
        Expected directory: \(command.workingDirectoryPath)

        \(details)

        Only stop this if it belongs to this project.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Stop")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func appleScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func project(from item: NSMenuItem) -> Project? {
        guard let id = item.representedObject as? UUID else {
            return nil
        }

        return store.projects.first { $0.id == id }
    }

    private func selectedCommand(from item: NSMenuItem) -> (project: Project, value: Project.Command)? {
        guard let selection = item.representedObject as? CommandSelection,
              let project = store.projects.first(where: { $0.id == selection.projectID }),
              let command = project.commands.first(where: { $0.id == selection.commandID }) else {
            return nil
        }

        return (project, command)
    }

    private func presentManagementWindow(projectID: UUID?, commandID: UUID?) {
        if managementWindowController == nil {
            managementWindowController = ManagementWindowController(
                store: store,
                processController: processController,
                onChange: { [weak self] in
                    self?.lastStatus = "Updated profiles"
                    self?.rebuildMenu()
                },
                openLogs: { [weak self] project, command in
                    self?.openLogInTerminal(project: project, command: command)
                }
            )
        }

        managementWindowController?.select(projectID: projectID, commandID: commandID)
        managementWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
