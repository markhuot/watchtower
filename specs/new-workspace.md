# New Workspace

## Summary

Add a generic "New Workspace..." action that creates a new terminal pane running an environment defined by a workspace script. The default behavior creates a git worktree, but users can override it with a custom script that does anything -- `docker exec`, `ssh`, `nix develop`, etc. The script itself becomes the command running inside the terminal, so interactive sessions like SSH and Docker just work.

## Motivation

Developers frequently need isolated environments: git worktrees for parallel feature work, Docker containers for reproducible builds, SSH sessions into dev sandboxes. Today each of these requires manual terminal commands. A single "New Workspace" action that is customizable per-project turns a multi-step workflow into one click.

## Key Insight: The Script *Is* the Terminal

Ghostty's surface config has a `command` field that overrides which process runs inside the terminal. Instead of running a script *before* opening the terminal (capturing its output and using that to configure a new shell), the workspace script **becomes the command that the terminal runs**.

This means:
- A script ending with `exec $SHELL` drops the user into a shell in a worktree directory.
- A script ending with `exec docker exec -it mycontainer bash` gives the user an interactive Docker session.
- A script ending with `exec ssh dev-sandbox` gives the user an SSH session.
- No race conditions, no output parsing, no two-phase setup.

## Detailed Design

### 1. Detecting Git Repositories

**What to track:** The `gitRepoRoot: String?` on `TerminalContainerViewModel` must stay in sync with the *focused* terminal's current working directory at all times. This means it must update in response to three events:

1. **The focused terminal's `directory` changes** (e.g., the user runs `cd` and the shell reports a new working directory via `GHOSTTY_ACTION_PWD`).
2. **Focus moves to a different terminal** (the new terminal may be in a different directory, or not in a git repo at all).
3. **A terminal is removed** (the newly focused terminal may differ).

**Reactive mechanism:** `TerminalContainerViewModel` uses a Combine pipeline that:

1. Observes which terminal is focused (by watching `terminals` and their `isFocused` properties).
2. Uses `switchToLatest` (or equivalent) to subscribe to the focused terminal's `$directory` publisher.
3. On each new directory value, runs `git -C <dir> rev-parse --show-toplevel` asynchronously.
4. Publishes the result to `@Published var gitRepoRoot: String?`.

This ensures the toolbar button is always correct -- whether the user `cd`'d into a repo, `cd`'d out of one, switched focus to a different pane, or closed a pane.

**How:** Run `git -C <dir> rev-parse --show-toplevel` via `Process` asynchronously. This is the canonical way to detect git repos and handles all edge cases (worktrees, submodules, bare repos). It returns the repo root path which we need for worktree creation and script discovery.

**Performance:** ~5ms per invocation, only runs on directory changes or focus changes. Result is cached on the view model as `gitRepoRoot: String?`. A `nil` value means "not in a git repo."

**Worked example:**

| Step | Event | Focused directory | `gitRepoRoot` | Button |
|---|---|---|---|---|
| 1 | Open window | `~/` | `nil` | (+) |
| 2 | `cd ~/Sites/eyes` | `~/Sites/eyes` | `~/Sites/eyes` | (+) dropdown |
| 3 | Open new tab (inherits dir) | `~/Sites/eyes` | `~/Sites/eyes` | (+) dropdown |
| 4 | Focus back to pane 1 | `~/Sites/eyes` | `~/Sites/eyes` | (+) dropdown |
| 5 | `cd ~/` in pane 1 | `~/` | `nil` | (+) |

### 2. Toolbar Button

**Current:** A plain `Button` with a `plus` icon calling `addTerminal()`.

**Proposed:** When `gitRepoRoot != nil`, swap for a `Menu` with `primaryAction`:

```swift
.toolbar {
    ToolbarItem(placement: .primaryAction) {
        if viewModel.gitRepoRoot != nil {
            Menu {
                Button("New Workspace...") {
                    viewModel.showWorkspaceDialog = true
                }
            } label: {
                Image(systemName: "plus")
            } primaryAction: {
                viewModel.addTerminal()
            }
        } else {
            Button(action: { viewModel.addTerminal() }) {
                Image(systemName: "plus")
            }
        }
    }
}
```

SwiftUI's `Menu` with `primaryAction` (macOS 12+) renders as a button with a small dropdown chevron. Primary click still creates a plain terminal. The chevron reveals "New Workspace...". This matches the UX pattern used by Safari's tab button and Xcode's run button.

### 3. Keyboard Shortcut

**Cmd+Shift+T** for "New Workspace..."

Added to `WatchtowerApp.swift`'s `.commands {}` block:

```swift
Button("New Workspace...") {
    activeViewModel?.showWorkspaceDialog = true
}
.keyboardShortcut("t", modifiers: [.command, .shift])
.disabled(activeViewModel?.gitRepoRoot == nil)
```

Disabled (greyed out in menu) when not in a git repo.

### 4. Workspace Dialog

A SwiftUI `.sheet()` presented from `ContentView`. Uses text fields rather than `NSAlert` since we need structured input.

**Dialog contents:**

| Field | Type | Default | Notes |
|---|---|---|---|
| Workspace name | `TextField` | Three random hyphenated words (e.g., `maple-lantern-coast`) | Used as the branch name and worktree directory name |
| Base branch | `TextField` | Current git branch (via `git branch --show-current`) | What to branch from; plain text field for v1 |
| OK / Cancel | Buttons | OK is default (responds to Enter) | OK disabled while workspace name is empty |

**Random word generation:** An embedded list of ~200 common, easy-to-type, inoffensive nouns. Three words gives 8M+ combinations. No network requests or dependencies. The list lives in a `WordList.swift` file.

**Getting the current branch:** `git -C <dir> branch --show-current` via `Process`. Falls back to `git rev-parse --short HEAD` for detached HEAD.

### 5. Workspace Creation Flow

After the user clicks OK:

```
1. Find the workspace script (if any)
2. Build the command string
3. Create a new TerminalModel with command set
4. The terminal surface runs the command directly
```

#### Step 1: Script Discovery

Look for `.watchtower/new-workspace.*` in the git repo root. Scan for files matching this glob pattern and select the first match found. Supported extensions and their interpreters:

| File | Interpreter |
|---|---|
| `new-workspace.sh` | `bash` (or `/usr/bin/env bash`) |
| `new-workspace.py` | `python3` (or `/usr/bin/env python3`) |
| `new-workspace.ts` | `npx tsx` |
| `new-workspace.rb` | `ruby` (or `/usr/bin/env ruby`) |
| `new-workspace.js` | `node` |
| (no extension) | Execute directly (must be `chmod +x`) |

If multiple `new-workspace.*` files exist, prefer in the order listed above. In practice this shouldn't happen -- if it does, the first match is deterministic and predictable.

#### Step 2: Build the Command

**If a custom script exists**, the command is:

```bash
bash -c 'cd "<repo-root>" && exec <interpreter> .watchtower/new-workspace.sh "<workspace-name>" "<base-branch>"'
```

The script receives the dialog values as positional arguments and the repo root as its working directory. The script is expected to end with `exec <something>` to replace itself with the final process (a shell, docker, ssh, etc.). If the script exits without exec'ing, the terminal closes (or stays open if we set `wait_after_command`).

**If no custom script exists**, the command is the default git worktree flow:

```bash
bash -c 'cd "<repo-root>" && git worktree add -b "<workspace-name>" "./work/<workspace-name>" "<base-branch>" && cd "./work/<workspace-name>" && exec "$SHELL"'
```

This creates the worktree, `cd`s into it, and replaces bash with the user's login shell. The terminal looks and behaves exactly like a normal shell session from that point on.

#### Step 3: Create the Terminal

Create a new `TerminalModel` with an additional `command: String?` property (defaults to `nil` for normal terminals). Pass it through to `GhosttyTerminalView`, which sets `surfaceConfig.command` when non-nil:

```swift
// In setupView()
terminal.directory.withCString { cDir in
    surfaceConfig.working_directory = cDir
    if let command = terminal.command {
        command.withCString { cCmd in
            surfaceConfig.command = cCmd
            self.surface = ghostty_surface_new(app, &surfaceConfig)
        }
    } else {
        self.surface = ghostty_surface_new(app, &surfaceConfig)
    }
}
```

The `directory` on the new model is set to the repo root (so the initial `cwd` is correct for the script). The `command` does the rest.

### 6. Custom Script Contract

**Arguments:**

| Position | Value |
|---|---|
| `$1` | Workspace name (the branch/directory name from the dialog) |
| `$2` | Base branch name |

**Environment variables:**

| Variable | Value |
|---|---|
| `WATCHTOWER_REPO_ROOT` | Absolute path to the git repo root |
| `WATCHTOWER_WORKSPACE_NAME` | Same as `$1` |
| `WATCHTOWER_BASE_BRANCH` | Same as `$2` |

Environment variables are passed via `ghostty_surface_config_s.env_vars` in addition to positional arguments, so scripts in any language can access them easily.

**Expected behavior:**

The script should `exec` into the final interactive process at the end. Examples:

```bash
#!/bin/bash
# Default worktree behavior (what Watchtower does without a script)
git worktree add -b "$1" "./work/$1" "$2"
cd "./work/$1"
exec $SHELL
```

```bash
#!/bin/bash
# Docker-based workspace
docker compose up -d "$1"
exec docker exec -it "$1" bash
```

```bash
#!/bin/bash
# SSH into a dev sandbox
exec ssh -t "dev-$1.internal" "cd /workspace && bash"
```

```python
#!/usr/bin/env python3
# new-workspace.py
import os, sys, subprocess
name, base = sys.argv[1], sys.argv[2]
subprocess.run(["git", "worktree", "add", "-b", name, f"./work/{name}", base], check=True)
subprocess.run(["pip", "install", "-r", f"./work/{name}/requirements.txt"], check=True)
os.chdir(f"./work/{name}")
os.execlp(os.environ["SHELL"], os.environ["SHELL"])
```

**If the script exits without `exec`:**
The terminal will show the script's output and then the process ends. We set `wait_after_command = true` on the surface config so the terminal stays open showing the output (including any error messages) rather than immediately closing. The user can see what happened and close the pane manually.

### 7. Error Handling

Since the script *is* the terminal process, errors are naturally visible:

- If `git worktree add` fails, the error appears in the terminal and the shell starts (or the script exits and the terminal stays open with `wait_after_command`).
- If a custom script has a syntax error, the interpreter's error message appears in the terminal.
- If `docker exec` can't connect, the Docker error appears in the terminal.

No special error dialog is needed for runtime errors -- the terminal *is* the error display. This is simpler and more Unix-philosophy than capturing stderr and showing it in a modal.

Pre-flight validation (before creating the terminal) is limited to:
- Checking that the workspace name is non-empty.
- Checking that the workspace script (if any) exists and is readable.

### 8. What About Non-Git Directories?

For v1, the "New Workspace..." option only appears in git repos because the default behavior (worktree creation) requires git, and the dialog fields (branch name, base branch) are git-specific.

Future iterations could:
- Show "New Workspace..." even outside git repos if a `.watchtower/new-workspace.*` script exists in the current directory (or any parent).
- Change the dialog fields based on context (no branch fields outside git).

This is deferred to keep v1 focused.

## Open Questions and Risks

### 1. App Sandbox and Process Spawning

The app has App Sandbox enabled. The `command` field on Ghostty's surface config goes through Ghostty's own process spawning (which already works -- it spawns shells). So the workspace command should work the same way. However, if the command invokes `docker`, `ssh`, or other binaries, those need to be accessible from the sandbox. This needs runtime testing.

**Mitigation:** Ghostty already handles arbitrary `command` configs (users can set `command = /usr/local/bin/fish` etc.), so the sandbox should allow it.

### 2. Script Interpreter Discovery

The script interpreter lookup (`bash`, `python3`, `npx tsx`) assumes these are on `PATH`. If they're not, the command fails -- but the error appears in the terminal, which is fine.

### 3. The `work/` Directory Convention

The default worktree path `./work/<name>` may conflict with projects that use `work/` for other purposes. The custom script is the escape hatch.

### 4. Worktree Cleanup

Out of scope for v1. Could be a future feature: a context menu on panes in worktree directories offering `git worktree remove`.

### 5. The `exec` Requirement

If users forget to `exec` at the end of their script, the terminal process ends and stays open (via `wait_after_command`). This is a reasonable failure mode -- the terminal shows all output and the user can close it. Documentation should emphasize the `exec` pattern.

### 6. `wait_after_command` Behavior

We set `wait_after_command = true` on workspace terminals so that if the command exits (script error, SSH disconnect, Docker container stop), the terminal stays open showing the output. This is better than the terminal silently disappearing. The user can still close the pane manually.

However, this means a normal `exit` from a shell inside a workspace will also leave the terminal open. This may feel slightly odd. Alternative: only set `wait_after_command` when using a custom script, and not for the default worktree flow (which exec's into `$SHELL` and behaves like a normal terminal).

**Recommendation:** Set `wait_after_command = true` only when a custom script is used. The default worktree flow exec's `$SHELL`, so the terminal behaves normally and closes on exit via the existing `ghosttySurfaceClosed` notification path.

## Implementation Plan

1. **Add `command: String?` to `TerminalModel`** -- optional, `nil` for normal terminals.
2. **Wire `command` through to `GhosttyTerminalView`** -- set `surfaceConfig.command` when non-nil.
3. **Add git detection** to `TerminalContainerViewModel` -- `gitRepoRoot: String?` updated on focused directory changes.
4. **Swap the toolbar button** for a conditional `Menu`/`Button` based on `gitRepoRoot`.
5. **Add Cmd+Shift+T** keyboard shortcut in `WatchtowerApp.swift`.
6. **Create the workspace dialog** as a SwiftUI `.sheet()` with workspace name and base branch fields.
7. **Implement random word generation** with an embedded word list.
8. **Implement workspace creation** -- build the command string (default worktree or custom script).
9. **Implement script discovery** -- find `.watchtower/new-workspace.*` and select interpreter.
10. **Open the new terminal** with the command and repo root as working directory.

## Files to Create or Modify

| File | Action | Description |
|---|---|---|
| `TerminalModel.swift` | Modify | Add `command: String?` property, add `env: [String: String]?` property |
| `GhosttyTerminalView.swift` | Modify | Set `surfaceConfig.command` and `surfaceConfig.env_vars` when present |
| `ContentView.swift` | Modify | Add `gitRepoRoot` to view model, conditional toolbar button, `.sheet()` presentation |
| `WatchtowerApp.swift` | Modify | Add Cmd+Shift+T keyboard shortcut |
| `WorkspaceDialogView.swift` | Create | SwiftUI sheet view with workspace name / base branch fields |
| `WorkspaceManager.swift` | Create | Git detection, script discovery, command string building |
| `WordList.swift` | Create | Embedded word list and random name generator |
