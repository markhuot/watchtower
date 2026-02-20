import SwiftUI

struct TerminalPaneView: View {
    @ObservedObject var terminal: TerminalModel
    @ObservedObject private var appManager = GhosttyAppManager.shared
    
    private let cornerRadius: CGFloat = 6
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            TerminalHeaderView(terminal: terminal)
                .frame(height: 40)
            
            // Terminal content area - use GeometryReader to get accurate size
            GeometryReader { geo in
                GhosttyTerminalView(terminal: terminal, size: geo.size)
            }
        }
        .background(appManager.backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(
                    terminal.isFocused
                        ? appManager.highlightColor
                        : Color.clear,
                    lineWidth: 2
                )
                .shadow(
                    color: terminal.isFocused
                        ? appManager.highlightColor.opacity(0.6)
                        : Color.clear,
                    radius: 8
                )
        )
        .animation(.easeInOut(duration: 0.15), value: terminal.isFocused)
    }
}

struct TerminalHeaderView: View {
    @ObservedObject var terminal: TerminalModel
    @ObservedObject private var appManager = GhosttyAppManager.shared
    
    var body: some View {
        HStack(spacing: 8) {
            // Status indicator — glowing circle
            StatusCircle(status: terminal.status)
            
            // Title (from terminal/running program)
            Text(terminal.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)
            
            Spacer()
        }
        .padding(.horizontal, 12)
        .background(appManager.backgroundColor.opacity(0.8))
    }
}

struct StatusCircle: View {
    let status: TerminalStatus
    
    var body: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
            .shadow(color: statusColor.opacity(0.8), radius: 4, x: 0, y: 0)
    }
    
    private var statusColor: Color {
        switch status {
        case .running:
            return .yellow
        case .succeeded:
            return .green
        case .failed:
            return .red
        }
    }
}

struct TerminalPaneView_Previews: PreviewProvider {
    static var previews: some View {
        TerminalPaneView(terminal: TerminalModel(
            id: UUID(),
            title: "vim",
            status: .running,
            directory: "/Users/username/projects"
        ))
        .frame(width: 760, height: 600)
    }
}
