import SwiftUI

struct SettingsView: View {
    @ObservedObject private var config = WatchtowerConfig.shared

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
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gear") }
        }
        .frame(width: 450, height: 200)
    }
}
