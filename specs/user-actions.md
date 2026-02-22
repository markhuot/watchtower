# User Actions

## Summary

Replace the hardcoded "New Workspace..." action with a general-purpose, user-configurable actions system. Users place executable scripts in `.watchtower/actions/` inside their project, and each script automatically appears as an entry in the toolbar dropdown menu. Scripts declare their arguments via `# @argument` comment annotations, and Watchtower presents a dialog with the appropriate fields before running the script as a terminal command.

A global actions directory at `~/.config/watchtower/actions/` provides personal actions available in every project.

## Motivation

The "New Workspace" spec (see `specs/new-workspace.md`) introduced a single action — creating a git worktree — with a hardcoded dialog (workspace name + base branch). But the underlying mechanism (run a script as the terminal process) is powerful and general. Users should be able to define their own actions:

- **New Agent** — open a Claude Code / Aider / Goose session in a new pane
- **New REPL** — open `rails console`, `python`, `iex`, or whatever the project uses
- **New Container** — `docker exec` into a running dev container
- **New SSH Session** — connect to a dev sandbox
- **New Worktree** — the original new-workspace behavior, now just one action among many

By making actions discoverable from the filesystem and self-describing via annotations, Watchtower becomes a project-aware terminal multiplexer that adapts to each team's workflow without any changes to the app itself.

## Detailed Design

### 1. Action Discovery

On every change to the focused terminal's working directory (or focus change between terminals), Watchtower discovers available actions. The dropdown always reflects the **focused terminal's project** — switching focus between terminals in different projects changes the available actions.

**Per-project discovery algorithm:**

1. Start from the focused terminal's current working directory.
2. Check if `.watchtower/actions/` exists at this level.
3. If not, go to the parent directory and repeat.
4. Stop at the filesystem root or the user's home directory (whichever comes first).
5. If found, enumerate all non-hidden files in the directory (non-recursive). Each file is one action.

**Global actions directory:**

Also check `~/.config/watchtower/actions/`. Global actions are available in every terminal, regardless of working directory. If both a project action and a global action have the same filename, the project action takes precedence (the global one is hidden).

**Merged action list:** Project actions appear first in the dropdown, followed by a separator, followed by global actions. If there are no project actions, global actions appear without a separator. If there are no global actions, no separator is shown.

**File filtering:** Hidden files (dotfiles like `.helper.sh`) are ignored. This follows Unix convention and lets users place helper scripts, includes, or shared libraries in the actions directory without them appearing in the menu.

**Reactivity:** Action discovery is reactive, not static. Global actions (`~/.config/watchtower/actions/`) are loaded once at app launch and cached. Per-directory actions are re-discovered whenever:

- A terminal's working directory changes (e.g., the user runs `cd` and Ghostty reports the new cwd).
- Focus switches between terminals.

Each terminal independently tracks its own discovered per-directory actions based on its own current working directory. The toolbar dropdown reflects the **focused terminal's** merged action list (its per-directory actions + the global actions).

**Performance:** The directory walk (checking for `.watchtower/actions/` up the tree) is fast since it only checks for directory existence at each level, not file contents. Action files are parsed (annotations read) only when a `.watchtower/actions/` directory is found. Results are cached per-directory-path and invalidated when the terminal's cwd changes. FSEvents-based live reloading (detecting changes to action files while the directory stays the same) is deferred — users restart Watchtower or `cd` away and back to pick up file changes.

**Relationship to git detection:** Action discovery is independent of git. A project doesn't need to be a git repo to have actions. However, git detection (from the new-workspace spec) is still useful for actions that need the git root — it's passed as the `WATCHTOWER_GIT_ROOT` environment variable (see Section 6).

### 2. Action File Format

Each file in an actions directory is an executable script. The filename (minus extension) becomes the action's display name by default, with hyphens and underscores converted to spaces and title-cased.

**Filename to display name mapping:**

| Filename | Display Name |
|---|---|
| `new-workspace.sh` | New Workspace |
| `new-agent.sh` | New Agent |
| `rails-console` | Rails Console |
| `open_repl.py` | Open Repl |

The display name is derived literally from the filename — no automatic stripping of numeric prefixes or other transformations. If you name a file `01-new-workspace.sh`, the display name is `01 New Workspace`. Use the `@name` annotation (below) to override this.

**Ordering:** Actions appear in alphabetical order by filename. Users can prefix with numbers to control order: `01-new-workspace.sh`, `02-new-agent.sh`.

**Annotations** are declared in comments at the top of the file:

```
# @name Custom Display Name
# @description A short explanation of what this action does
# @argument VARIABLE_NAME The human-readable label for this field
# @default VARIABLE_NAME some default value
# @options VARIABLE_NAME $(command that outputs one option per line)
```

#### `@name` — Display name override

```
# @name New Git Worktree
```

Overrides the filename-derived display name. Useful when the filename needs to be terse for ordering (`01-worktree.sh`) but the menu label should be descriptive. If not present, the display name is derived from the filename as described above.

#### `@description` — Action description

```
# @description Create a new git worktree and open a shell in it
```

Provides a short description shown as subtitle or tooltip text in the dropdown menu. Optional — if not present, only the display name is shown.

#### `@argument` — Declare a dialog field

```
# @argument VARIABLE_NAME The human-readable label for this field
```

- `VARIABLE_NAME` — the environment variable name the value will be passed as (also used as `$VARIABLE_NAME` in shell scripts). All caps, underscores allowed.
- Everything after the variable name — the label shown in the dialog's text field.

By default, an argument renders as a text field. If `@options` is also declared for the same variable, it renders as a dropdown/picker instead (see below).

#### `@default` — Set initial field value

```
# @default VARIABLE_NAME some default value
# @default VARIABLE_NAME $(git branch --show-current)
```

Sets the initial value for an argument's field. If the value starts with `$(` and ends with `)`, it's executed as a shell command and the output (trimmed) is used as the default. This lets actions like "new workspace" default the base branch to the current git branch.

For arguments with `@options`, the `@default` value selects which option is pre-selected. If no `@default` is specified, the first option is selected.

#### `@options` — Provide choices for an argument

```
# @options VARIABLE_NAME $(git branch --format='%(refname:short)')
# @options VARIABLE_NAME staging, production, dev
```

Replaces the text field for this argument with a dropdown/picker. The value is either:

- **A `$(...)` command** — executed as a shell command. Each line of output becomes one option. Empty lines are ignored. The command runs asynchronously when the dialog opens (same as `@default`).
- **A comma-separated list** — static options parsed at discovery time. Whitespace around each option is trimmed.

If the command fails, the dropdown is replaced with a text field as a fallback, and an inline error hint is shown (same behavior as failed `@default` commands).

**Example — branch picker:**

```bash
# @argument BASE The base branch
# @options BASE $(git branch --format='%(refname:short)')
# @default BASE $(git branch --show-current)
```

This renders a dropdown of all local branches, with the current branch pre-selected.

**Example — static choices:**

```bash
# @argument ENV The target environment
# @options ENV staging, production, dev
# @default ENV staging
```

### 3. Parsing Rules

Watchtower reads the first 50 lines of each action file looking for annotations. Parsing stops at the first non-comment, non-blank, non-shebang line (i.e., once actual code starts).

**Comment prefixes recognized:**

| Prefix | Languages |
|---|---|
| `#` | bash, sh, python, ruby, zsh |
| `//` | javascript, typescript, swift, go |

The parser strips the comment prefix and leading whitespace, then matches against `@name`, `@description`, `@argument`, `@default`, or `@options` at the start of the remaining text.

**Example — a "New Workspace" action (`.watchtower/actions/01-new-workspace.sh`):**

```bash
#!/bin/bash

# @name New Workspace
# @description Create a new git worktree and open a shell in it
# @argument NAME The new workspace name
# @default NAME $(ruby -e "puts %w[maple cedar pine oak birch elm ash hazel rowan ivy].sample(3).join('-')")
# @argument BASE The base branch
# @options BASE $(git branch --format='%(refname:short)')
# @default BASE $(git branch --show-current)

set -e
git worktree add -b "$NAME" ".watchtower/workspaces/$NAME" "$BASE"
cd ".watchtower/workspaces/$NAME"
exec $SHELL
```

**Example — a "New Agent" action (`.watchtower/actions/02-new-agent.sh`):**

```bash
#!/bin/bash

# @name New Agent
# @description Start a Claude Code session with a task description
# @argument TASK Describe the task for the agent

exec claude "$TASK"
```

**Example — a "Rails Console" action with no arguments (`.watchtower/actions/rails-console.sh`):**

```bash
#!/bin/bash

exec bundle exec rails console
```

When an action has zero `@argument` annotations, it runs immediately on click — no dialog is shown.

### 4. Toolbar Integration

The toolbar button behavior changes based on action discovery:

| State | Toolbar Appearance |
|---|---|
| No custom actions found (no project or global actions) | Plain `+` button (creates a new terminal, no dropdown) |
| One or more custom actions found | `+` button with dropdown chevron |

**Dropdown contents (example with both project and global actions):**

```
[Click +]          → New terminal (always, primary action)
[Click chevron ▾]  →  New Terminal
                      ─────────────
                      New Workspace...
                      New Agent...
                      Rails Console
                      ─────────────
                      SSH Dev Box
```

"New Terminal" always appears as both the primary click action (clicking the `+` directly) **and** the first entry in the dropdown. This gives discoverable access to the new-terminal action for users who don't realize they can click the `+` directly, and provides a consistent target in the menu.

Actions with arguments get an ellipsis (`...`) appended to their display name (standard macOS convention indicating a dialog will appear). Actions without arguments have no ellipsis and execute immediately.

**Every action opens a new terminal pane.** This matches the mental model of the `+` button — you're adding a new pane. There is no option to run an action in the currently focused terminal.

This replaces the conditional `Menu`/`Button` from the new-workspace spec. The logic is the same — `Menu` with `primaryAction` — but the dropdown is now dynamically populated from the actions directories.

### 5. Action Dialog

When the user selects an action that has arguments, a dialog sheet appears with one text field per `@argument`, in declaration order.

**Dialog layout:**

| Element | Behavior |
|---|---|
| Title | The action's display name (from `@name` or filename) |
| Fields | One labeled `TextField` per `@argument`, using the label text. Pre-filled with `@default` value if present. |
| Cancel | Dismiss, do nothing |
| Run | Execute the action (default button, responds to Enter). Disabled while any field is empty. |

**Default value resolution:** When the dialog opens, any `@default` annotations with `$(...)` commands are executed asynchronously. The field shows a placeholder while the command runs.

**Default command errors:** If a `$(...)` default command fails (non-zero exit, or the binary doesn't exist), the field is left empty and a small inline error hint is shown below the field (e.g., "Default command failed"). This tells the user why the field is blank instead of silently swallowing the error. The user can still type a value manually.

Default and options commands run with the **focused terminal's current working directory** as their working directory. This means `git` commands will work correctly as long as the terminal is inside a git repo, and scripts can reference files relative to where the user is currently working.

### 6. Action Execution

When the user clicks "Run" (or selects a no-argument action directly):

1. **Build environment variables** from the dialog fields. Each `@argument VARIABLE_NAME` maps to an environment variable of the same name. Arguments are passed as environment variables only — not as positional arguments. This keeps the contract simple, self-documenting, and consistent across all scripting languages.

2. **Build the command string.** Watchtower constructs a shell command string that execs the action script. This is the same approach used by the current workspace creation flow (`WorkspaceManager.buildCommand`). Environment variables are passed separately via the `TerminalModel.env` dictionary (not baked into the command string).

   - If the file has the executable bit set (`chmod +x`), the command execs the script directly (e.g., `exec /path/to/script.sh`). The OS handles interpreter selection via the shebang line.
   - If not executable and has a recognized extension, the command execs the appropriate interpreter with the script path (e.g., `exec /usr/bin/env bash /path/to/script.sh`). See Section 11.
   - If not executable and no recognized extension, the command prints an error message to the terminal (e.g., `echo "Error: script.foo is not executable and has no recognized extension"`).

   The command string is passed as `TerminalModel.command`, which flows through to `surfaceConfig.command` in `GhosttyTerminalView`.

3. **Create a new `TerminalModel`** with:
   - `command` set to the constructed shell wrapper command string
   - `directory` set to the focused terminal's current working directory
   - `env` set to a dictionary containing the argument values plus context variables
   - `waitAfterCommand` set to `true` (so the terminal stays open if the script exits)

**Environment variables passed to every action:**

| Variable | Value |
|---|---|
| `WATCHTOWER_GIT_ROOT` | Absolute path to git repo root, if in a git repo. Empty string otherwise. |
| `WATCHTOWER_ACTION` | The action filename (e.g., `new-workspace.sh`) |
| *(argument variables)* | One per `@argument`, with the user-provided value |

4. **Open the terminal.** The script runs as the terminal process (same mechanism as the new-workspace spec — the script *is* the terminal). Interactive commands like `exec ssh ...` or `exec docker exec ...` just work.

### 7. The Script *Is* the Terminal (Inherited from new-workspace spec)

This carries forward the key insight from the new-workspace spec. The action script becomes the command that the terminal runs. See that spec's "Key Insight" section for the full rationale.

All action-spawned terminals have `waitAfterCommand` set to `true` (see Section 6, step 3). If the script exits — whether from an error or normal completion — the terminal stays open showing the output. This prevents the pane from vanishing on failure and lets the user read error messages.

### 8. Error Handling

Inherits the same philosophy as the new-workspace spec — the terminal *is* the error display:

- Script syntax errors → interpreter error appears in terminal
- Missing commands → shell error appears in terminal
- Failed operations → error output appears in terminal

Pre-flight validation:
- Check that the script file exists and is readable before launching.
- If a script isn't executable and has no recognized extension (can't determine interpreter), show a brief error in the terminal: `"Error: <filename> is not executable and has no recognized extension"`.

### 9. Shipping a Default Action

Watchtower does not bundle default action scripts or auto-create the `.watchtower/actions/` directory. The actions system is entirely opt-in. Documentation (and perhaps a "Getting Started" section in a future welcome screen) will provide example scripts users can copy.

The new-workspace spec's "default worktree flow" (the fallback when no custom script exists) is removed. If a user wants the worktree action, they create a script in `.watchtower/actions/`. This keeps the system simple and uniform — there's one mechanism, not two.

### 10. Relationship to the New Workspace Spec

This spec supersedes Sections 2 (toolbar button), 4 (workspace dialog), 5 (workspace creation flow), and 6 (custom script contract) of the new-workspace spec. The following parts of that spec are still relevant and carry forward:

| New Workspace Spec Section | Status |
|---|---|
| 1. Detecting Git Repositories | **Retained** — still needed for `WATCHTOWER_GIT_ROOT` env var and future features |
| 2. Toolbar Button | **Superseded** — now dynamically populated from actions directories |
| 3. Keyboard Shortcut | **Deferred** — consider a shortcut to open the actions menu in the future |
| 4. Workspace Dialog | **Superseded** — generalized into the action dialog |
| 5. Workspace Creation Flow | **Superseded** — generalized into action execution |
| 6. Custom Script Contract | **Superseded** — generalized into action file format |
| 7. Error Handling | **Retained** — same philosophy |
| 8. Non-Git Directories | **Resolved** — actions work everywhere, not just git repos |

### 11. Interpreter Detection

When running an action script, Watchtower determines how to execute it:

1. **Executable bit set** — if the file has `+x`, execute it directly. The OS reads the shebang line and handles interpreter selection via `execve`. This is the preferred path and respects the script author's intent.

2. **Not executable, recognized extension** — if the file lacks `+x` but has a known extension, invoke it through the corresponding interpreter:

| Extension | Interpreter |
|---|---|
| `.sh` | `/usr/bin/env bash` |
| `.bash` | `/usr/bin/env bash` |
| `.zsh` | `/usr/bin/env zsh` |
| `.py` | `/usr/bin/env python3` |
| `.rb` | `/usr/bin/env ruby` |
| `.js` | `/usr/bin/env node` |
| `.ts` | `/usr/bin/env npx tsx` |

This fallback exists as a convenience so users don't have to `chmod +x` their scripts. But `chmod +x` with a shebang is the recommended approach.

3. **Not executable, no recognized extension** — error (see Section 8).

## Open Questions

### 1. App Sandbox

The app has App Sandbox enabled. Ghostty already handles arbitrary commands (users can set custom shells, etc.), so action scripts should work the same way. If sandbox restrictions surface during testing, we'll address them then. This is not a blocker for implementation.

### 2. Command palette integration

A future command palette (Cmd+K or similar) would be a natural way to access actions without the toolbar dropdown. When the command palette is implemented, actions should appear as searchable entries. This is out of scope for this spec but noted as a design direction — it's why per-action `@shortcut` annotations were intentionally deferred.

## Implementation Plan

1. **Action model and parser** — `Action` struct and parser that reads a script file, extracts `@name`, `@description`, `@argument`, `@default`, and `@options` annotations, derives display name.
2. **Action discovery** — walk up from the focused terminal's current working directory to find `.watchtower/actions/`, also check `~/.config/watchtower/actions/`, enumerate and parse scripts, filter dotfiles, merge results with project actions taking precedence. Global actions are loaded once at app launch; per-directory actions re-discovered reactively on cwd changes and focus changes.
3. **Wire discovery into the view model** — `actions: [Action]` on `TerminalContainerViewModel`, updated reactively using the existing Combine pipeline that tracks the focused terminal's directory (same pattern as the current `gitRepoRoot` detection).
4. **Dynamic toolbar dropdown** — populate the `Menu` entries from discovered actions, with "New Terminal" as both the primary action and first dropdown entry. Separator between "New Terminal" and project actions, and between project and global actions. Show `@description` as subtitle text. Show plain `+` button (no dropdown) when there are zero custom actions.
5. **Action dialog** — generic sheet view that takes an `Action` and presents its arguments as text fields or dropdown pickers (when `@options` is present), with inline error hints for failed defaults/options.
6. **Default and options resolution** — execute `$(...)` defaults and options commands concurrently (all in parallel) when the dialog opens, using the focused terminal's cwd. Show inline error hint on failure, fall back to text field for failed `@options`.
7. **Action execution** — check executable bit, determine interpreter if needed, build a `bash -c '...'` shell wrapper command string, build environment variables (no positional args), create a `TerminalModel` with `command`, `env`, and `waitAfterCommand: true`, open the terminal.
8. **Remove hardcoded workspace logic** — delete `WorkspaceDialogView.swift` and the workspace-specific parts of `WorkspaceManager.swift` (retain `detectGitRepoRoot` and `currentBranch`). The new-workspace behavior is now just an example action script in documentation.

## Files to Create or Modify

| File | Action | Description |
|---|---|---|
| `Action.swift` | Create | Model struct: `name`, `displayName`, `description`, `scriptPath`, `arguments: [Argument]`, `defaults`, `options`, `isGlobal` |
| `ActionParser.swift` | Create | Parse a script file for `@name`, `@description`, `@argument`, `@default`, `@options` annotations; derive display name from filename |
| `ActionDiscovery.swift` | Create | Walk directory tree to find `.watchtower/actions/`, check `~/.config/watchtower/actions/`, enumerate and parse scripts, filter dotfiles, merge and dedupe. Expose as async function callable from Combine pipeline. |
| `ActionDialogView.swift` | Create | Generic SwiftUI sheet that renders text fields or dropdown pickers per argument, with inline error hints for failed defaults/options |
| `ContentView.swift` | Modify | Replace conditional toolbar button with dynamic action menu; add sheet presentation for action dialog; wire reactive action discovery into the existing Combine pipeline |
| `TerminalContainerViewModel` (in ContentView or extracted) | Modify | Add `actions: [Action]` published property; reactive discovery on focus/cwd changes |
| `WorkspaceManager.swift` | Modify | Remove `findWorkspaceScript`, `buildCommand`, `buildEnvVars`, `shellEscape`. Retain `detectGitRepoRoot` and `currentBranch`. |
| `WorkspaceDialogView.swift` | Delete | Superseded by `ActionDialogView.swift` |
| `GhosttyTerminalView.swift` | No change | Already supports `command`, `env`, and `waitAfterCommand` on `TerminalModel` |
| `TerminalModel.swift` | No change | Already has `command: String?`, `env: [String: String]?`, and `waitAfterCommand: Bool` properties |

## Example: Full Project Setup

A project with `.watchtower/actions/` containing three actions:

**`.watchtower/actions/01-new-workspace.sh`:**

```bash
#!/bin/bash

# @name New Workspace
# @description Create a new git worktree and open a shell in it
# @argument NAME The new workspace name
# @default NAME $(ruby -e "puts %w[maple cedar pine oak birch elm ash hazel rowan ivy willow aspen spruce larch juniper alder beech poplar yew holly sage fern brook stone cliff ridge vale mist frost dawn dusk vale pond creek bluff grove knoll marsh delta cove ledge peak pass ford glen moor dale fen tor].sample(3).join('-')")
# @argument BASE The base branch
# @options BASE $(git branch --format='%(refname:short)')
# @default BASE $(git branch --show-current)

set -e

git worktree add -b "$NAME" ".watchtower/workspaces/$NAME" "$BASE"
cd ".watchtower/workspaces/$NAME"
exec $SHELL
```

**`.watchtower/actions/02-new-agent.sh`:**

```bash
#!/bin/bash

# @name New Agent
# @description Start a Claude Code session with a task description
# @argument TASK Describe the task for the agent

exec claude "$TASK"
```

**`.watchtower/actions/rails-console.sh`:**

```bash
#!/bin/bash

# @description Open an interactive Rails console

exec bundle exec rails console
```

And a global action in **`~/.config/watchtower/actions/ssh-dev.sh`:**

```bash
#!/bin/bash

# @name SSH Dev Box
# @description Connect to the dev sandbox via SSH

exec ssh dev-sandbox.internal
```

**Resulting dropdown:**

```
  New Terminal
  ─────────────
  New Workspace...       Create a new git worktree and open a shell in it
  New Agent...           Start a Claude Code session with a task description
  Rails Console          Open an interactive Rails console
  ─────────────
  SSH Dev Box            Connect to the dev sandbox via SSH
```
