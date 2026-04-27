import Foundation

final class CommandSelection: NSObject {
    let projectID: UUID
    let commandID: UUID

    init(projectID: UUID, commandID: UUID) {
        self.projectID = projectID
        self.commandID = commandID
    }
}

enum StartPortChoice {
    case start(Int?)
    case cancel
}

enum StatusIndicator {
    case stopped
    case starting
    case running
    case external
    case problem
}

struct CommandMenuState {
    let status: String
    let isRunning: Bool
    let isExternal: Bool
    let port: Int?
    let indicator: StatusIndicator
    let externalStopTitle: String?
    let lastErrorPreview: String?

    var localURL: URL? {
        guard let port else {
            return nil
        }

        return URL(string: "http://localhost:\(port)")
    }
}
