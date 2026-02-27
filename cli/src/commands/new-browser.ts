import { sendCommand, getPaneId } from "../ipc.ts";

function printUsage() {
  console.log(`Usage: watchtower new browser [options] [url]

Open a new browser pane in the current Watchtower window.

Arguments:
  url                       URL to open (default: about:blank)

Options:
  --webkit                  Use the WebKit rendering engine
  --chrome                  Use the Chromium rendering engine
  --remote-debugging-port <port>
                            Enable Chrome DevTools Protocol on the given port.
                            Implies --chrome. The port is process-wide: the first
                            call sets it for all Chromium panes. Subsequent calls
                            with a different port will warn but cannot change it.
  --help, -h                Show this help message

If no engine is specified, the app's configured default is used.

The new browser opens adjacent to the pane where this command is run.
If not running inside Watchtower, it opens in the first available window.

Examples:
  watchtower new browser https://example.com
  watchtower new browser --chrome http://localhost:3000
  watchtower new browser --chrome --remote-debugging-port 9222 http://localhost:3000
  watchtower new browser --webkit example.com`);
}

export async function newBrowser(args: string[]) {
  if (args.includes("--help") || args.includes("-h")) {
    printUsage();
    return;
  }

  let engine: string | undefined;
  let url: string | undefined;
  let remoteDebuggingPort: number | undefined;

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === "--webkit") {
      engine = "webkit";
    } else if (arg === "--chrome") {
      engine = "chromium";
    } else if (arg === "--remote-debugging-port") {
      const portStr = args[++i];
      if (!portStr || isNaN(Number(portStr))) {
        console.error("--remote-debugging-port requires a numeric port argument");
        printUsage();
        process.exit(1);
      }
      remoteDebuggingPort = Number(portStr);
      if (remoteDebuggingPort < 1 || remoteDebuggingPort > 65535) {
        console.error("Port must be between 1 and 65535");
        process.exit(1);
      }
      // Implies --chrome since CDP only works with Chromium
      if (!engine) {
        engine = "chromium";
      }
    } else if (arg.startsWith("-")) {
      console.error(`Unknown option: ${arg}`);
      printUsage();
      process.exit(1);
    } else {
      url = arg;
    }
  }

  if (remoteDebuggingPort !== undefined && engine === "webkit") {
    console.error("--remote-debugging-port is only supported with the Chromium engine, not WebKit");
    process.exit(1);
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
      ...(remoteDebuggingPort !== undefined && { remoteDebuggingPort }),
    });

    if (!response.ok) {
      console.error(`Error: ${response.error}`);
      process.exit(1);
    }

    // Print any warnings (e.g., port already set)
    if (response.warning) {
      console.error(`Warning: ${response.warning}`);
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
