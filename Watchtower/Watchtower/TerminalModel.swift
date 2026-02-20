import Foundation

class TerminalModel: Identifiable, ObservableObject {
    let id: UUID
    @Published var title: String
    @Published var status: TerminalStatus
    @Published var paneWidth: CGFloat
    @Published var isFocused: Bool = false
    @Published var isDragging: Bool = false
    var directory: String

    /// Default pane width: 80 columns * 9px per char + 40px padding
    static let defaultPaneWidth: CGFloat = 80 * 9 + 40

    init(id: UUID, title: String, status: TerminalStatus, directory: String, paneWidth: CGFloat = TerminalModel.defaultPaneWidth) {
        self.id = id
        self.title = title
        self.status = status
        self.directory = directory
        self.paneWidth = paneWidth
    }
}

enum TerminalStatus {
    case running
    case succeeded
    case failed
}
