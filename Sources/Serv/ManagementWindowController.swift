import AppKit
import ServCore

@MainActor
final class ManagementWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private struct CommandRow {
        let project: Project
        var command: Project.Command
    }

    private enum Filter: Equatable {
        case all
        case favorites
        case hidden
        case group(CommandGroup)

        var title: String {
            switch self {
            case .all:
                return "All"
            case .favorites:
                return "Favorites"
            case .hidden:
                return "Hidden"
            case .group(let group):
                return group.rawValue
            }
        }
    }

    private let store: ProjectStore
    private let processController: ProcessController
    private let onChange: () -> Void
    private let openLogs: (Project, Project.Command) -> Void
    private let searchField = NSSearchField()
    private let filterPopup = NSPopUpButton()
    private let tableView = NSTableView()
    private let dependencyLabel = NSTextField(labelWithString: "Select a profile")
    private let filters: [Filter] = [.all, .favorites, .hidden] + CommandGroup.allCases.map(Filter.group)
    private var rows: [CommandRow] = []
    private var pendingProjectID: UUID?
    private var pendingCommandID: UUID?

    init(
        store: ProjectStore,
        processController: ProcessController,
        onChange: @escaping () -> Void,
        openLogs: @escaping (Project, Project.Command) -> Void
    ) {
        self.store = store
        self.processController = processController
        self.onChange = onChange
        self.openLogs = openLogs
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Serv Profiles"
        super.init(window: window)
        buildUI()
        reload()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func select(projectID: UUID?, commandID: UUID?) {
        pendingProjectID = projectID
        pendingCommandID = commandID
        reload()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count, let identifier = tableColumn?.identifier.rawValue else {
            return nil
        }

        let cell = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier(identifier), owner: self)
            as? NSTableCellView ?? NSTableCellView()
        cell.identifier = NSUserInterfaceItemIdentifier(identifier)

        let textField = cell.textField ?? NSTextField(labelWithString: "")
        textField.lineBreakMode = .byTruncatingMiddle
        textField.maximumNumberOfLines = 1
        textField.translatesAutoresizingMaskIntoConstraints = false
        if cell.textField == nil {
            cell.addSubview(textField)
            cell.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }

        let row = rows[row]
        textField.stringValue = value(for: identifier, row: row)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateDependencyStatus()
    }

    private func buildUI() {
        guard let contentView = window?.contentView else {
            return
        }

        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            root.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14)
        ])

        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        searchField.placeholderString = "Search projects, profiles, commands"
        searchField.target = self
        searchField.action = #selector(searchChanged)
        filterPopup.addItems(withTitles: filters.map(\.title))
        filterPopup.target = self
        filterPopup.action = #selector(filterChanged)
        toolbar.addArrangedSubview(searchField)
        toolbar.addArrangedSubview(filterPopup)
        NSLayoutConstraint.activate([
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
            filterPopup.widthAnchor.constraint(equalToConstant: 140)
        ])
        root.addArrangedSubview(toolbar)

        configureTable()
        let scrollView = NSScrollView()
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.documentView = tableView
        root.addArrangedSubview(scrollView)

        let controls = NSStackView()
        controls.orientation = .horizontal
        controls.spacing = 8
        for button in [
            makeButton("Pin", action: #selector(toggleFavorite)),
            makeButton("Hide/Show", action: #selector(toggleHidden)),
            makeButton("Edit Profile", action: #selector(editProfile)),
            makeButton("Edit Env", action: #selector(editEnvironment)),
            makeButton("Open Logs", action: #selector(openSelectedLogs))
        ] {
            controls.addArrangedSubview(button)
        }
        controls.addArrangedSubview(NSView())
        root.addArrangedSubview(controls)

        dependencyLabel.lineBreakMode = .byTruncatingTail
        root.addArrangedSubview(dependencyLabel)
    }

    private func configureTable() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.headerView = NSTableHeaderView()

        for column in [
            ("project", "Project", 160.0),
            ("group", "Type", 90.0),
            ("name", "Profile", 160.0),
            ("status", "Status", 130.0),
            ("flags", "Flags", 90.0),
            ("command", "Command", 300.0)
        ] {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.0))
            tableColumn.title = column.1
            tableColumn.width = column.2
            tableView.addTableColumn(tableColumn)
        }
    }

    private func makeButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func reload() {
        rows = filteredRows()
        tableView.reloadData()
        restoreSelection()
        updateDependencyStatus()
    }

    private func filteredRows() -> [CommandRow] {
        let search = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filter = filters[filterPopup.indexOfSelectedItem]
        return store.projects
            .flatMap { project in
                project.commands.map { CommandRow(project: project, command: $0) }
            }
            .filter { row in
                matches(filter: filter, command: row.command) && matches(search: search, row: row)
            }
            .sorted { lhs, rhs in
                let left = "\(lhs.project.name) \(lhs.command.group.rawValue) \(lhs.command.name)"
                let right = "\(rhs.project.name) \(rhs.command.group.rawValue) \(rhs.command.name)"
                return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
            }
    }

    private func matches(filter: Filter, command: Project.Command) -> Bool {
        switch filter {
        case .all:
            return true
        case .favorites:
            return command.isFavorite
        case .hidden:
            return command.isHidden
        case .group(let group):
            return command.group == group
        }
    }

    private func matches(search: String, row: CommandRow) -> Bool {
        guard !search.isEmpty else {
            return true
        }
        let searchable = [
            row.project.name,
            row.project.path,
            row.command.name,
            row.command.display,
            row.command.workingDirectoryPath,
            row.command.reason
        ]
        .joined(separator: " ")
        .lowercased()
        return searchable.contains(search)
    }

    private func restoreSelection() {
        guard !rows.isEmpty else {
            return
        }

        let index = rows.firstIndex { row in
            let projectMatches = pendingProjectID == nil || row.project.id == pendingProjectID
            let commandMatches = pendingCommandID == nil || row.command.id == pendingCommandID
            return projectMatches && commandMatches
        } ?? 0
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
    }

    private func value(for identifier: String, row: CommandRow) -> String {
        switch identifier {
        case "project":
            return row.project.name
        case "group":
            return row.command.group.rawValue
        case "name":
            return row.command.name
        case "status":
            return processController.state(for: row.project, command: row.command).status
        case "flags":
            return [
                row.command.isFavorite ? "Pinned" : nil,
                row.command.isHidden ? "Hidden" : nil
            ]
            .compactMap { $0 }
            .joined(separator: ", ")
        case "command":
            return row.command.display
        default:
            return ""
        }
    }

    private func selectedRow() -> CommandRow? {
        let index = tableView.selectedRow
        guard index >= 0, index < rows.count else {
            return nil
        }
        return rows[index]
    }

    private func update(_ command: Project.Command, in project: Project) {
        store.upsert(command: command, in: project.id)
        pendingProjectID = project.id
        pendingCommandID = command.id
        onChange()
        reload()
    }

    @objc private func searchChanged() {
        reload()
    }

    @objc private func filterChanged() {
        reload()
    }

    @objc private func toggleFavorite() {
        guard var row = selectedRow() else {
            return
        }
        row.command.isFavorite.toggle()
        update(row.command, in: row.project)
    }

    @objc private func toggleHidden() {
        guard var row = selectedRow() else {
            return
        }
        row.command.isHidden.toggle()
        update(row.command, in: row.project)
    }

    @objc private func editProfile() {
        guard var row = selectedRow() else {
            return
        }

        let alert = NSAlert()
        alert.messageText = "Edit profile"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8

        let nameField = NSTextField(string: row.command.name)
        nameField.placeholderString = "Profile name"

        let groupPopup = NSPopUpButton()
        groupPopup.addItems(withTitles: CommandGroup.allCases.map(\.rawValue))
        groupPopup.selectItem(withTitle: row.command.group.rawValue)

        let healthField = NSTextField(string: row.command.healthURLString ?? "")
        healthField.placeholderString = "Health URL, optional"

        for field in [nameField, groupPopup, healthField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(field)
            field.widthAnchor.constraint(equalToConstant: 360).isActive = true
        }
        alert.accessoryView = stack

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        row.command.name = name.isEmpty ? row.command.name : name
        if let group = CommandGroup.allCases.first(where: { $0.rawValue == groupPopup.titleOfSelectedItem }) {
            row.command.group = group
        }
        let health = healthField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        row.command.healthURLString = health.isEmpty ? nil : health
        update(row.command, in: row.project)
    }

    @objc private func editEnvironment() {
        guard var row = selectedRow() else {
            return
        }

        let alert = NSAlert()
        alert.messageText = "Edit environment"
        alert.informativeText = "Use KEY=value, one per line."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 180))
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.string = row.command.environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")

        let scrollView = NSScrollView(frame: textView.frame)
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView
        alert.accessoryView = scrollView

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        row.command.environment = parseEnvironment(textView.string)
        update(row.command, in: row.project)
    }

    @objc private func openSelectedLogs() {
        guard let row = selectedRow() else {
            return
        }
        openLogs(row.project, row.command)
    }

    private func updateDependencyStatus() {
        guard let row = selectedRow() else {
            dependencyLabel.stringValue = "Select a profile"
            return
        }

        let executable = row.command.executable == "/bin/zsh" ? "zsh" : row.command.executable
        let dependency = Self.findExecutable(executable)
        let envCount = row.command.environment.count
        let health = row.command.healthURLString ?? "default localhost check"
        if let dependency {
            dependencyLabel.stringValue = "Dependency: \(executable) at \(dependency) | Env vars: \(envCount) | Health: \(health)"
        } else {
            dependencyLabel.stringValue = "Missing dependency: \(executable) | Env vars: \(envCount) | Health: \(health)"
        }
    }

    private func parseEnvironment(_ text: String) -> [String: String] {
        text.split(separator: "\n").reduce(into: [:]) { environment, rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty,
                  !line.hasPrefix("#"),
                  let separator = line.firstIndex(of: "=") else {
                return
            }

            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                return
            }
            environment[key] = value
        }
    }

    nonisolated private static func findExecutable(_ executable: String) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", executable]
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
