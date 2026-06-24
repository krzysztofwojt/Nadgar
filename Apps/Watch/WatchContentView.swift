import SwiftUI
import WristAssistShared

struct WatchContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = WatchVoiceViewModel()
    private let bottomID = "chat-bottom"
    private let chatBottomReadableInset: CGFloat = 78
    private let chatAccentColor = Color(red: 0.07, green: 0.46, blue: 1)

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            if viewModel.hasAPIKey {
                chatView
                    .ignoresSafeArea(.container, edges: .bottom)
            } else {
                missingAPIKeyView
            }
        }
        .task {
            await viewModel.requestInitialSettings()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                Task {
                    await viewModel.prepareForForeground()
                }
            case .inactive, .background:
                viewModel.suspendAudioWarmup()
            @unknown default:
                viewModel.suspendAudioWarmup()
            }
        }
    }

    private var missingAPIKeyView: some View {
        Text("Open WristAssist on your iPhone and save API key.")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 10)
    }

    private var chatView: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(viewModel.messages) { message in
                            messageBubble(message)
                                .id(message.id)
                        }

                        Color.clear
                            .frame(height: chatBottomReadableInset)
                            .id(bottomID)
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                }
                .scrollIndicators(.hidden)
                .onAppear {
                    scrollToBottom(proxy)
                }
                .onChange(of: viewModel.messages) { _, _ in
                    scrollToBottom(proxy)
                }
                .onChange(of: viewModel.pttState) { _, _ in
                    scrollToBottom(proxy)
                }

                topReadableGradient
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)

                pushToTalkMicrophoneButton
                    .padding(.trailing, 18)
                    .padding(.bottom, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.container, edges: .bottom)
        }
    }

    private func messageBubble(_ message: ChatMessage) -> some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 24)
            }

            messageText(message)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .frame(maxWidth: 170, alignment: .leading)
                .background(message.role == .user ? chatAccentColor : Color.white.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            if message.role == .assistant {
                Spacer(minLength: 24)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    @ViewBuilder
    private func messageText(_ message: ChatMessage) -> some View {
        if message.isPlaceholder {
            Text(message.text)
                .font(.system(size: 13, weight: .regular))
                .italic()
                .lineSpacing(1)
                .foregroundStyle(.white.opacity(0.76))
                .multilineTextAlignment(.leading)
        } else {
            Text(message.text)
                .font(.system(size: 13, weight: .medium))
                .lineSpacing(1)
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
        }
    }

    private var topReadableGradient: some View {
        LinearGradient(
            colors: [
                Color.black.opacity(0.9),
                Color.black.opacity(0.52),
                Color.black.opacity(0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 56)
        .ignoresSafeArea(.container, edges: .top)
    }

    private var pushToTalkMicrophoneButton: some View {
        ZStack {
            if viewModel.isProcessing {
                ProcessingDotsIcon()
                    .transition(.opacity.combined(with: .scale(scale: 0.86)))
            } else {
                Image(systemName: "mic.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .transition(.opacity.combined(with: .scale(scale: 0.86)))
            }
        }
            .frame(width: 66, height: 44)
            .foregroundStyle(.white)
            .pttGlassButton(tint: microphoneButtonTint, isInteractive: viewModel.hasAPIKey && !viewModel.isProcessing)
            .scaleEffect(viewModel.isPushToTalkRecording ? 1.08 : 1)
            .shadow(color: microphoneButtonTint.opacity(0.34), radius: 18, x: 0, y: 0)
            .shadow(color: microphoneButtonTint.opacity(0.2), radius: 7, x: 0, y: 2)
            .shadow(color: .black.opacity(0.28), radius: 8, x: 0, y: 3)
            .animation(.easeInOut(duration: 0.14), value: viewModel.isPushToTalkRecording)
            .animation(.easeInOut(duration: 0.18), value: viewModel.isProcessing)
            .contentShape(Capsule(style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        viewModel.beginPushToTalkRecording()
                    }
                    .onEnded { _ in
                        viewModel.endPushToTalkRecording()
                    }
            )
            .allowsHitTesting(viewModel.hasAPIKey && !viewModel.isProcessing)
            .accessibilityLabel(viewModel.isProcessing ? "Processing" : "Microphone")
            .accessibilityAddTraits(.isButton)
    }

    private var microphoneButtonTint: Color {
        if viewModel.isPushToTalkRecording {
            return Color(red: 1, green: 0.12, blue: 0.18)
        }

        if viewModel.isProcessing {
            return Color(red: 0.5, green: 0.55, blue: 0.62)
        }

        return chatAccentColor
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo(bottomID, anchor: .bottom)
        }
    }
}

private struct ProcessingDotsIcon: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    let wave = dotWave(at: timeline.date, index: index)

                    Circle()
                        .fill(.white)
                        .frame(width: 6, height: 6)
                        .opacity(0.42 + wave * 0.58)
                        .scaleEffect(0.72 + wave * 0.32)
                }
            }
        }
        .frame(width: 32, height: 22)
        .accessibilityHidden(true)
    }

    private func dotWave(at date: Date, index: Int) -> Double {
        let phase = date.timeIntervalSinceReferenceDate * 1.4 - Double(index) * 0.18
        return (sin(phase * .pi * 2) + 1) / 2
    }
}

private extension View {
    @ViewBuilder
    func pttGlassButton(tint: Color, isInteractive: Bool) -> some View {
        if #available(watchOS 26.0, *) {
            self
                .background {
                    ZStack {
                        Capsule(style: .continuous)
                            .fill(.white.opacity(0.08))
                        Capsule(style: .continuous)
                            .fill(tint.opacity(0.04))
                    }
                }
                .glassEffect(
                    .regular.tint(tint.opacity(0.3)).interactive(isInteractive),
                    in: Capsule(style: .continuous)
                )
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(.white.opacity(0.58), lineWidth: 0.8)
                }
        } else {
            self
                .background(.ultraThinMaterial, in: Capsule(style: .continuous))
                .overlay {
                    Capsule(style: .continuous)
                        .fill(tint.opacity(0.12))
                }
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(.white.opacity(0.46), lineWidth: 0.8)
                }
        }
    }
}
