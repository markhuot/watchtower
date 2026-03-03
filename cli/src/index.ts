#!/usr/bin/env bun

import { newTerminal } from "./commands/new-terminal.ts";
import { newBrowser } from "./commands/new-browser.ts";
import { closePane } from "./commands/close.ts";
import { focusNext } from "./commands/focus-next.ts";
import { focusPrevious } from "./commands/focus-previous.ts";
import { focusPane } from "./commands/focus-pane.ts";
import { focusMode } from "./commands/focus-mode.ts";
import { moveLeft } from "./commands/move-left.ts";
import { moveRight } from "./commands/move-right.ts";
import { collapse } from "./commands/collapse.ts";
import { expand } from "./commands/expand.ts";
import { fit } from "./commands/fit.ts";
import { back } from "./commands/back.ts";
import { forward } from "./commands/forward.ts";
import { reload } from "./commands/reload.ts";
import { navigate } from "./commands/navigate.ts";
import { switchEngine } from "./commands/switch-engine.ts";
import { clearHistory } from "./commands/clear-history.ts";
import { fullscreen } from "./commands/fullscreen.ts";
import { minimize } from "./commands/minimize.ts";
import { zoom } from "./commands/zoom.ts";
import { setColor } from "./commands/set-color.ts";
import { setStatus } from "./commands/set-status.ts";
import { centerPane } from "./commands/center-pane.ts";
import { installOpencode } from "./commands/install-opencode.ts";

const CLI_VERSION = "0.1.0";
const args = process.argv.slice(2);

function printUsage() {
  console.log(`Usage: watchtower <command> [options]

Commands:
  new terminal    Open a new terminal pane
  new browser     Open a new browser pane
  close           Close a pane (--right to close panes to the right)

  focus next      Focus the next pane
  focus previous  Focus the previous pane
  focus pane      Focus a specific pane by ID
  focus mode      Toggle focus mode

  move left       Move the focused pane left
  move right      Move the focused pane right
  collapse        Collapse the focused pane
  expand          Expand the focused pane
  fit             Fit all panes to the window
  center pane     Scroll the focused pane to the center of the window

  back            Browser: go back
  forward         Browser: go forward
  reload          Browser: reload page
  navigate        Browser: navigate to a URL
  switch engine   Browser: switch rendering engine

  clear-history   Clear all browsing history
  fullscreen      Toggle full screen
  minimize        Minimize the window
  zoom            Zoom the window
  set color       Set the pane header color (hex or --reset)
  set status      Set the pane status (active|idle|failed)
  install opencode  Install Watchtower plugin for OpenCode

Options:
  --help, -h      Show this help message
  --version, -v   Show the CLI version

Environment:
  WATCHTOWER_PANE_ID   Automatically set by Watchtower in each terminal.
                       Used to identify the calling pane for adjacent placement.`);
}

// Only show top-level help if no subcommand is given
if (
  args.length === 0 ||
  (args.length === 1 && (args[0] === "--help" || args[0] === "-h"))
) {
  printUsage();
  process.exit(0);
}

if (args.length === 1 && (args[0] === "--version" || args[0] === "-v")) {
  console.log(`watchtower v${CLI_VERSION}`);
  process.exit(0);
}

// Single-word commands
const singleWordCommands: Record<string, (args: string[]) => Promise<void>> = {
  close: closePane,
  collapse,
  expand,
  fit,
  back,
  forward,
  reload,
  navigate,
  "clear-history": clearHistory,
  fullscreen,
  minimize,
  zoom,
};

// Two-word commands
const twoWordCommands: Record<string, (args: string[]) => Promise<void>> = {
  "new terminal": newTerminal,
  "new browser": newBrowser,
  "focus next": focusNext,
  "focus previous": focusPrevious,
  "focus pane": focusPane,
  "focus mode": focusMode,
  "move left": moveLeft,
  "move right": moveRight,
  "switch engine": switchEngine,
  "set color": setColor,
  "set status": setStatus,
  "center pane": centerPane,
  "install opencode": installOpencode,
};

const firstArg = args[0];

// Try single-word command first
if (firstArg in singleWordCommands) {
  await singleWordCommands[firstArg](args.slice(1));
} else if (args.length >= 2) {
  // Try two-word command
  const twoWord = args.slice(0, 2).join(" ");
  if (twoWord in twoWordCommands) {
    await twoWordCommands[twoWord](args.slice(2));
  } else {
    console.error(`Unknown command: ${args.join(" ")}`);
    printUsage();
    process.exit(1);
  }
} else {
  console.error(`Unknown command: ${args.join(" ")}`);
  printUsage();
  process.exit(1);
}
