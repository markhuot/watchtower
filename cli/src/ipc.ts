import { homedir } from "os";
import { join } from "path";

const SOCKET_PATH = join(homedir(), ".config", "watchtower", "watchtower.sock");

export interface IPCRequest {
  command: string;
  paneId?: string;
  [key: string]: unknown;
}

export interface IPCResponse {
  ok: boolean;
  error?: string;
  paneId?: string;
  [key: string]: unknown;
}

/**
 * Send a command to the running Watchtower app via Unix domain socket.
 * Uses Bun's native socket API (node:net doesn't support Unix sockets in Bun).
 * Returns the parsed JSON response.
 */
export function sendCommand(request: IPCRequest): Promise<IPCResponse> {
  return new Promise((resolve, reject) => {
    let data = "";
    let settled = false;

    const timeout = setTimeout(() => {
      if (!settled) {
        settled = true;
        reject(new Error("Connection to Watchtower timed out"));
      }
    }, 5000);

    Bun.connect({
      unix: SOCKET_PATH,
      socket: {
        open(socket) {
          const payload = JSON.stringify(request) + "\n";
          socket.write(payload);
          socket.flush();
          socket.shutdown();
        },
        data(socket, chunk) {
          data += chunk.toString();
        },
        close() {
          if (settled) return;
          settled = true;
          clearTimeout(timeout);
          try {
            const response = JSON.parse(data.trim()) as IPCResponse;
            resolve(response);
          } catch {
            reject(new Error(`Invalid response from Watchtower: ${data}`));
          }
        },
        error(_socket, err) {
          if (settled) return;
          settled = true;
          clearTimeout(timeout);
          reject(err);
        },
      },
    }).catch((err: Error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      if (
        err.message.includes("ENOENT") ||
        err.message.includes("ECONNREFUSED")
      ) {
        reject(
          new Error("Could not connect to Watchtower. Is the app running?")
        );
      } else {
        reject(err);
      }
    });
  });
}

/**
 * Get the WATCHTOWER_PANE_ID from the environment.
 * Returns undefined if not running inside a Watchtower terminal.
 */
export function getPaneId(): string | undefined {
  return process.env["WATCHTOWER_PANE_ID"];
}
