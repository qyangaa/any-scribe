import SwiftUI
import ScribeCore

/// Auto-scrolling live transcript with Me/Them labels, bound to the recorder view model.
struct LiveTranscriptView: View {
    @ObservedObject var viewModel: RecorderViewModel

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if viewModel.lines.isEmpty {
                Spacer()
                emptyState
                Spacer()
            } else {
                transcript
            }
        }
        .frame(minWidth: 420, minHeight: 320)
    }

    @ViewBuilder private var emptyState: some View {
        switch viewModel.state {
        case .starting:
            VStack(spacing: 8) {
                ProgressView()
                Text("Loading the model… first start takes a few seconds.")
                    .foregroundStyle(.secondary)
            }
        case .recording:
            Text("Listening… transcript will appear here.").foregroundStyle(.secondary)
        case .stopping:
            Text("Saving transcript…").foregroundStyle(.secondary)
        case .idle:
            Text("Not recording. Click the menu-bar icon to start.").foregroundStyle(.secondary)
        }
    }

    private var statusLabel: (String, Color) {
        switch viewModel.state {
        case .idle:      return ("Idle", .secondary)
        case .starting:  return ("Loading model…", .orange)
        case .recording: return ("Recording", .red)
        case .stopping:  return ("Saving…", .secondary)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(statusLabel.1).frame(width: 9, height: 9)
            Text(statusLabel.0).font(.headline)
            Spacer()
            Text("\(viewModel.micLabel) = mic · \(viewModel.systemLabel) = system audio")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(viewModel.lines.enumerated()), id: \.offset) { index, entry in
                        lineText(for: entry).id(index)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: viewModel.lines.count) { _ in
                if let last = viewModel.lines.indices.last {
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }

    private func lineText(for line: Recorder.Line) -> Text {
        let color: Color = line.label == viewModel.micLabel ? .blue : .green
        return Text("\(Self.clock.string(from: line.time)) ")
            .font(.caption.monospaced()).foregroundColor(.secondary)
            + Text("\(line.label): ").bold().foregroundColor(color)
            + Text(line.text)
    }
}
