import Foundation
import Combine

class TerminalModel: Identifiable, ObservableObject {
    let id: UUID
    @Published var title: String
    @Published var status: TerminalStatus
    @Published var paneWidth: CGFloat
    @Published var isFocused: Bool = false
    @Published var isDragging: Bool = false
    @Published var directory: String

    /// The current git branch name for this terminal's working directory.
    /// `nil` when not inside a git repository.
    @Published var gitBranch: String? = nil

    /// Optional command to run instead of the default shell.
    /// When set, this becomes the process running inside the terminal.
    let command: String?

    /// Optional environment variables to pass to the terminal process.
    let env: [String: String]?

    /// Whether the terminal should stay open after the command exits.
    /// Set to `true` for workspace terminals with custom scripts.
    let waitAfterCommand: Bool

    /// Default pane width: 80 columns * 9px per char + 40px padding
    static let defaultPaneWidth: CGFloat = 80 * 9 + 40

    /// In-flight git branch detection task, cancelled when directory changes.
    private var branchDetectionTask: Task<Void, Never>? = nil

    /// Combine subscription for directory changes.
    private var cancellables = Set<AnyCancellable>()

    /// The directory path with the home directory prefix replaced by `~`.
    var abbreviatedDirectory: String {
        let home = NSHomeDirectory()
        if directory == home {
            return "~"
        } else if directory.hasPrefix(home + "/") {
            return "~" + directory.dropFirst(home.count)
        }
        return directory
    }

    init(
        id: UUID,
        title: String,
        status: TerminalStatus,
        directory: String,
        paneWidth: CGFloat = TerminalModel.defaultPaneWidth,
        command: String? = nil,
        env: [String: String]? = nil,
        waitAfterCommand: Bool = false
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.directory = directory
        self.paneWidth = paneWidth
        self.command = command
        self.env = env
        self.waitAfterCommand = waitAfterCommand

        // Reactively detect git branch whenever directory changes
        $directory
            .removeDuplicates()
            .sink { [weak self] dir in
                self?.detectGitBranch(for: dir)
            }
            .store(in: &cancellables)
    }

    /// Detect the git branch for the given directory asynchronously.
    private func detectGitBranch(for directory: String) {
        branchDetectionTask?.cancel()
        branchDetectionTask = Task { @MainActor [weak self] in
            let root = await WorkspaceManager.detectGitRepoRoot(for: directory)
            guard !Task.isCancelled else { return }
            if root != nil {
                let branch = await WorkspaceManager.currentBranch(for: directory)
                guard !Task.isCancelled else { return }
                self?.gitBranch = branch
            } else {
                self?.gitBranch = nil
            }
        }
    }
}

enum TerminalStatus {
    /// The surface has an active foreground process (e.g. vim, a build).
    case active
    /// The surface is idle at a shell prompt — no foreground process running.
    case idle
    /// The child process exited with a non-zero exit code.
    case failed
}
