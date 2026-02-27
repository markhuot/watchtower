import { sendCommand, getPaneId } from "../ipc.ts";

function printUsage() {
  console.log(`Usage: watchtower new browser [options] [url]

Open a new browser pane in the current Watchtower window.

Arguments:
  url                       URL to open (default: about:blank)

Options:
  --webkit                  Use the WebKit rendering engine
  --chrome                  Use the Chromium rendering engine
  --help, -h                Show this help message

If no engine is specified, the app's configured default is used.

The new browser opens adjacent to the pane where this command is run.
If not running inside Watchtower, it opens in the first available window.

Examples:
  watchtower new browser https://example.com
  watchtower new browser --chrome http://localhost:3000
  watchtower new browser --webkit example.com`);
}

export async function newBrowser(args: string[]) {
  if (args.includes("--help") || args.includes("-h")) {
    printUsage();
    return;
  }

  let engine: string | undefined;
  let url: string | undefined;

  for (const arg of args) {
    if (arg === "--webkit") {
      engine = "webkit";
    } else if (arg === "--chrome") {
      engine = "chromium";
    } else if (arg.startsWith("-")) {
      console.error(`Unknown option: ${arg}`);
      printUsage();
      process.exit(1);
    } else {
      url = arg;
    }
  }

  // If a URL was given without a scheme, prepend https://
  if (url && !url.match(/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//)) {
    url = `https://${url}`;
  }

  const paneId = getPaneId();

  try {
    const response = await sendCommand({
      command: "new-browser",
      paneId,
      ...(url && { url }),
      ...(engine && { engine }),
    });

    if (!response.ok) {
      console.error(`Error: ${response.error}`);
      process.exit(1);
    }

    // Output the new pane ID so scripts can use it
    if (response.paneId) {
      console.log(response.paneId);
    }
  } catch (err) {
    console.error(`${(err as Error).message}`);
    process.exit(1);
  }
}
