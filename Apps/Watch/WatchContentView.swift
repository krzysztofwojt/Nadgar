import SwiftUI
import WristAssistShared

struct WatchContentView: View {
    @StateObject private var viewModel = WatchVoiceViewModel()

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            Group {
                if !viewModel.hasAPIKey {
                    missingAPIKeyView
                } else if viewModel.isIdle {
                    readyView
                } else {
                    activeView
                }
            }
            .padding(.horizontal, 8)
        }
        .task {
            await viewModel.requestInitialSettings()
        }
    }

    private var missingAPIKeyView: some View {
        Text("Open WristAssist on your iPhone and save API key.")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
    }

    private var readyView: some View {
        VStack(spacing: 14) {
            microphoneButton

            Button("Click to start") {
                viewModel.startOrStop()
            }
            .buttonStyle(.plain)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.black)
            .frame(minWidth: 118, minHeight: 34)
            .background(Color.white)
            .clipShape(Capsule())
            .accessibilityLabel("Start conversation")
        }
    }

    private var activeView: some View {
        VStack(spacing: 10) {
            microphoneButton

            Text(viewModel.state.displayName)
                .font(.headline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var microphoneButton: some View {
        Button {
            viewModel.startOrStop()
        } label: {
            Image(systemName: viewModel.isRunning ? "stop.fill" : "mic.fill")
                .font(.system(size: 30, weight: .semibold))
                .frame(width: 76, height: 76)
                .background(viewModel.isRunning ? Color.red : Color.green)
                .foregroundStyle(.white)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(viewModel.isRunning ? "Stop conversation" : "Start conversation")
    }
}
