import SwiftUI

struct SettingsView: View {
    @ObservedObject private var config = WatchtowerConfig.shared
    @State private var cliInstallStatus: CLIInstallStatus = .unknown

    var body: some View {
        TabView {
            Form {
                Picker("Browser Rendering Engine", selection: $config.browserEngine) {
                    ForEach(BrowserEngine.allCases, id: \.self) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                .pickerStyle(.menu)
                Text(config.browserEngine.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Changes apply to new browser panes. Existing panes keep their current engine until switched via the command palette.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Divider()

                Picker("Search Engine", selection: $config.searchEngine) {
                    ForEach(SearchEngine.allCases, id: \.self) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                .pickerStyle(.menu)
                Text("The search engine used by \"Search the web\" in the command palette.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if config.searchEngine == .custom {
                    TextField("Search URL (use %s for query)", text: $config.customSearchURL)
                        .textFieldStyle(.roundedBorder)
                    Text("Example: https://search.example.com/?q=%s")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Divider()

                Toggle("Enable Chrome Debugging Protocol", isOn: $config.enableChromeDebugging)
                HStack {
                    Text("Remote Debugging Port")
                    Spacer()
                    TextField("9222", value: $config.chromiumRemoteDebuggingPort, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                }
                Text("Remote debugging is always active for in-pane DevTools (\"Inspect Element\"). Enable Chrome Debugging Protocol to also allow external CDP clients (chrome://inspect). Port changes require app restart.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Command Line Interface")
                        switch cliInstallStatus {
                        case .unknown:
                            Text("Checking...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        case .installed:
                            Text("Installed at \(CLIInstaller.installPath)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        case .notInstalled:
                            Text("Not installed")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        case .notBundled:
                            Text("CLI binary not found in app bundle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        case .error(let message):
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }

                    Spacer()

                    if cliInstallStatus == .installed {
                        Button("Reinstall") {
                            performInstall()
                        }
                    } else if cliInstallStatus == .notInstalled {
                        Button("Install") {
                            performInstall()
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gear") }
        }
        .frame(width: 450, height: 400)
        .onAppear {
            checkCLIStatus()
        }
    }

    private func checkCLIStatus() {
        if !CLIInstaller.isBundled {
            cliInstallStatus = .notBundled
        } else if CLIInstaller.isInstalled {
            cliInstallStatus = .installed
        } else {
            cliInstallStatus = .notInstalled
        }
    }

    private func performInstall() {
        do {
            try CLIInstaller.install()
            cliInstallStatus = .installed
        } catch {
            cliInstallStatus = .error(error.localizedDescription)
        }
    }
}

private enum CLIInstallStatus: Equatable {
    case unknown
    case installed
    case notInstalled
    case notBundled
    case error(String)
}
