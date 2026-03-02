import SwiftUI

struct SettingsView: View {
    @ObservedObject private var config = WatchtowerConfig.shared
    @State private var cliInstallStatus: CLIInstallState = .notBundled

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
                        case .notBundled:
                            Text("CLI binary not found in app bundle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        case .notInstalled(let bundledVersion):
                            if let bundledVersion {
                                Text("Not installed (bundled v\(bundledVersion))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Not installed")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        case .installedCurrent(let version):
                            if let version {
                                Text("Installed v\(version) at \(CLIInstaller.installPath)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Installed at \(CLIInstaller.installPath)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        case .installedOutdated(let installed, let bundled):
                            let installedText = installed ?? "unknown"
                            if let bundled {
                                Text("Outdated (installed v\(installedText), bundled v\(bundled))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Outdated (installed v\(installedText))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        case .installedNewer(let installed, let bundled):
                            let installedText = installed ?? "unknown"
                            if let bundled {
                                Text("Installed newer v\(installedText) (bundled v\(bundled))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Installed newer v\(installedText)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        case .error(let message):
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }

                    Spacer()

                    switch cliInstallStatus {
                    case .installedCurrent:
                        Button("Reinstall") {
                            performInstall()
                        }
                    case .installedOutdated:
                        Button("Update") {
                            performInstall()
                        }
                    case .notInstalled:
                        Button("Install") {
                            performInstall()
                        }
                    default:
                        EmptyView()
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
        cliInstallStatus = CLIInstaller.status()
    }

    private func performInstall() {
        do {
            try CLIInstaller.install()
            cliInstallStatus = CLIInstaller.status()
        } catch {
            cliInstallStatus = .error(error.localizedDescription)
        }
    }
}
