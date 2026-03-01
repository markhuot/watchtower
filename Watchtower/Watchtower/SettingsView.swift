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
        .frame(width: 450, height: 280)
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
