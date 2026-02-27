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

    /// Text to send to the terminal once the shell is ready.
    /// Used by the CLI to run a command in an interactive shell
    /// so the user can continue typing after it completes.
    let initialInput: String?

    /// Progress report from Ghostty's ConEmu OSC 9;4 protocol.
    @Published var progressReport: PaneProgress? = nil

    /// Auto-clear timer for progress reports (15 second timeout).
    private var progressClearTimer: Timer? = nil

    /// Timer that clears the bell indicator 1 second after the pane gains focus.
    private var bellClearTimer: Timer? = nil

    /// Combine subscription for focus changes (used to clear bell on focus).
    private var bellFocusCancellable: AnyCancellable? = nil

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
        waitAfterCommand: Bool = false,
        initialInput: String? = nil
    ) {
        self.terminalTitle = title
        self.terminalStatus = status
        self.terminalDirectory = directory
        self.command = command
        self.env = env
        self.waitAfterCommand = waitAfterCommand
        self.initialInput = initialInput

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

    /// Called when the terminal rings the bell (BEL character / \a).
    /// Sets `hasBell` on the pane. If the pane is already focused the
    /// bell indicator clears after 1 second; otherwise it persists until
    /// the pane receives focus and then clears 1 second later.
    func ringBell() {
        hasBell = true
        bellClearTimer?.invalidate()
        bellClearTimer = nil

        if isFocused {
            // Already focused — start the 1-second auto-clear now.
            scheduleBellClear()
        } else {
            // Not focused — observe isFocused and start the timer when it flips.
            bellFocusCancellable?.cancel()
            bellFocusCancellable = $isFocused
                .filter { $0 }          // only when becoming focused
                .first()                 // one-shot
                .sink { [weak self] _ in
                    self?.scheduleBellClear()
                }
        }
    }

    /// Schedule the bell indicator to clear after 1 second.
    private func scheduleBellClear() {
        bellClearTimer?.invalidate()
        bellClearTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            self?.hasBell = false
        }
        bellFocusCancellable?.cancel()
        bellFocusCancellable = nil
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
