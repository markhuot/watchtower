#!/usr/bin/env bun

import { newTerminal } from "./commands/new-terminal.ts";
import { newBrowser } from "./commands/new-browser.ts";

const args = process.argv.slice(2);

function printUsage() {
  console.log(`Usage: watchtower <command> [options]

Commands:
  new terminal    Open a new terminal pane
  new browser     Open a new browser pane

Options:
  --help, -h      Show this help message

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

// Parse subcommand: "new terminal" or "new browser"
const command = args.slice(0, 2).join(" ");
const commandArgs = args.slice(2);

switch (command) {
  case "new terminal":
    await newTerminal(commandArgs);
    break;
  case "new browser":
    await newBrowser(commandArgs);
    break;
  default:
    console.error(`Unknown command: ${args.join(" ")}`);
    printUsage();
    process.exit(1);
}
