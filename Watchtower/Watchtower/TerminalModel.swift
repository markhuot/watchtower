import Foundation
import Combine

class TerminalPaneModel: PaneModel {
    @Published var terminalTitle: String
    @Published var terminalStatus: PaneStatus
    @Published var terminalDirectory: String

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

    /// Progress report from Ghostty's ConEmu OSC 9;4 protocol.
    @Published var progressReport: PaneProgress? = nil

    /// Auto-clear timer for progress reports (15 second timeout).
    private var progressClearTimer: Timer? = nil

    /// In-flight git branch detection task, cancelled when directory changes.
    private var branchDetectionTask: Task<Void, Never>? = nil

    /// Combine subscription for directory changes.
    private var cancellables = Set<AnyCancellable>()

    /// The directory path with the home directory prefix replaced by `~`.
    var abbreviatedDirectory: String {
        let home = NSHomeDirectory()
        if terminalDirectory == home {
            return "~"
        } else if terminalDirectory.hasPrefix(home + "/") {
            return "~" + terminalDirectory.dropFirst(home.count)
        }
        return terminalDirectory
    }

    // MARK: - PaneModel overrides

    override var title: String { terminalTitle }
    override var subtitle: String? { abbreviatedDirectory + (gitBranch.map { ":" + $0 } ?? "") }
    override var status: PaneStatus { terminalStatus }
    override var progress: PaneProgress? { progressReport }
    override var directory: String? { terminalDirectory }

    init(
        id: UUID,
        title: String,
        status: PaneStatus,
        directory: String,
        paneWidth: CGFloat = PaneModel.defaultPaneWidth,
        command: String? = nil,
        env: [String: String]? = nil,
        waitAfterCommand: Bool = false
    ) {
        self.terminalTitle = title
        self.terminalStatus = status
        self.terminalDirectory = directory
        self.command = command
        self.env = env
        self.waitAfterCommand = waitAfterCommand

        super.init(id: id, paneWidth: paneWidth)

        // Reactively detect git branch whenever directory changes
        $terminalDirectory
            .removeDuplicates()
            .sink { [weak self] dir in
                self?.detectGitBranch(for: dir)
            }
            .store(in: &cancellables)
    }

    /// Update the progress report and reset the auto-clear timer.
    func updateProgressReport(_ progress: PaneProgress?) {
        progressReport = progress
        progressClearTimer?.invalidate()
        if progress != nil {
            progressClearTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: false) { [weak self] _ in
                self?.progressReport = nil
            }
        }
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
