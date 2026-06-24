import SwiftUI
import WristAssistShared

struct WatchContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = WatchVoiceViewModel()
    @State private var isMicrophoneDragActive = false
    @State private var microphoneDragTranslation: CGSize = .zero
    @State private var activeDragTarget: PTTDragTarget?
    @State private var hasPressedMicrophone = false
    private let bottomID = "chat-bottom"
    private let chatBottomReadableInset: CGFloat = 78
    private let chatAccentColor = Color(red: 0.07, green: 0.46, blue: 1)
    private let microphoneButtonSize = CGSize(width: 66, height: 44)
    private let microphoneHomeTrailing: CGFloat = 10
    private let microphoneHomeBottom: CGFloat = 16
    private let dragTargetSize = CGSize(width: 66, height: 44)
    private let dragTargetGlowSize = CGSize(width: 118, height: 118)
    private let dragTargetEdgeInset: CGFloat = 8
    private let cancelTargetLeadingInset: CGFloat = 6
    private let lockTargetTopInset: CGFloat = 20
    private let dragTargetHitPadding: CGFloat = 24
    private let lockedDragActivationThreshold: CGFloat = 8

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            if viewModel.hasAPIKey {
                chatView
                    .ignoresSafeArea(.container, edges: [.top, .bottom])
            } else {
                missingAPIKeyView
            }

            centeredClock
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 2)
                .ignoresSafeArea(.container, edges: .top)
                .allowsHitTesting(false)
        }
        .persistentSystemOverlays(.hidden)
        ._statusBarHidden(true)
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

    private var centeredClock: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            Text(timeline.date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 4, x: 0, y: 1)
        }
        .frame(height: 22)
    }

    private var chatView: some View {
        ScrollViewReader { proxy in
            GeometryReader { geometry in
                ZStack {
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
                    .onChange(of: viewModel.pttState) { _, newState in
                        scrollToBottom(proxy)

                        if newState != .recording {
                            resetMicrophoneDrag()
                        }
                    }

                    topReadableGradient
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .allowsHitTesting(false)

                    if shouldShowEmptyPrompt {
                        emptyPromptOverlay(in: geometry.size)
                    }

                    if isMicrophoneDragActive {
                        dragTargetsOverlay(in: geometry.size)
                    }

                    pushToTalkMicrophoneButton
                        .position(microphonePosition(in: geometry.size))
                        .animation(.spring(response: 0.22, dampingFraction: 0.78), value: isMicrophoneDragActive)
                        .gesture(microphoneDragGesture(in: geometry.size))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(.container, edges: [.top, .bottom])
            }
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

    private var shouldShowEmptyPrompt: Bool {
        viewModel.messages.isEmpty &&
            !hasPressedMicrophone &&
            !isMicrophoneDragActive &&
            viewModel.pttState == .ready
    }

    private func emptyPromptOverlay(in size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Text("To start,\npress and hold\nthe microphone\nbutton")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .lineSpacing(2)
                .foregroundStyle(.white.opacity(0.88))
                .multilineTextAlignment(.leading)
                .frame(width: min(size.width - 42, 174), alignment: .leading)
                .padding(.top, 42)
                .padding(.leading, 20)

            CurvedPromptArrow()
                .stroke(
                    chatAccentColor.opacity(0.78),
                    style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)
                )
                .frame(width: min(128, size.width - 96), height: 108)
                .position(x: size.width - 138, y: size.height - 58)
                .shadow(color: chatAccentColor.opacity(0.2), radius: 5, x: 0, y: 0)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
        .animation(.easeInOut(duration: 0.18), value: shouldShowEmptyPrompt)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func dragTargetsOverlay(in size: CGSize) -> some View {
        let lockFrame = dragTargetFrame(.lock, in: size)
        let cancelFrame = dragTargetFrame(.cancel, in: size)

        return ZStack {
            dragTargetPad(.cancel, isActive: activeDragTarget == .cancel)
                .frame(width: dragTargetGlowSize.width, height: dragTargetGlowSize.height)
                .position(x: cancelFrame.midX, y: cancelFrame.midY)

            if !viewModel.isRecordingLocked {
                dragTargetPad(.lock, isActive: activeDragTarget == .lock)
                    .frame(width: dragTargetGlowSize.width, height: dragTargetGlowSize.height)
                    .position(x: lockFrame.midX, y: lockFrame.midY)
            }
        }
        .frame(width: size.width, height: size.height)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
        .animation(.easeInOut(duration: 0.14), value: activeDragTarget)
        .allowsHitTesting(false)
    }

    private func dragTargetPad(_ target: PTTDragTarget, isActive: Bool) -> some View {
        ZStack {
            RadialGradient(
                colors: [
                    target.tint.opacity(isActive ? 0.82 : 0.54),
                    target.tint.opacity(isActive ? 0.45 : 0.28),
                    target.tint.opacity(isActive ? 0.16 : 0.1),
                    target.tint.opacity(0)
                ],
                center: .center,
                startRadius: isActive ? 2 : 4,
                endRadius: isActive ? 66 : 54
            )
            .scaleEffect(isActive ? 1.18 : 1)
            .blur(radius: isActive ? 2 : 3)

            Image(systemName: target.symbolName)
                .font(.system(size: isActive ? 29 : 24, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.32), radius: 3, x: 0, y: 1)
                .shadow(color: target.tint.opacity(isActive ? 0.75 : 0.38), radius: isActive ? 14 : 8, x: 0, y: 0)
        }
            .brightness(isActive ? 0.06 : 0)
            .animation(.spring(response: 0.18, dampingFraction: 0.66), value: isActive)
            .accessibilityHidden(true)
    }

    private var pushToTalkMicrophoneButton: some View {
        ZStack {
            if viewModel.isProcessing {
                ProcessingDotsIcon()
                    .transition(.opacity.combined(with: .scale(scale: 0.86)))
            } else if viewModel.isRecordingLocked {
                HStack(spacing: 7) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 20, weight: .semibold))
                    Image(systemName: "lock.fill")
                        .font(.system(size: 12, weight: .bold))
                        .baselineOffset(1)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.86)))
            } else {
                Image(systemName: "mic.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .transition(.opacity.combined(with: .scale(scale: 0.86)))
            }
        }
            .frame(width: 66, height: 44)
            .foregroundStyle(.white)
            .pttGlassButton(
                tint: microphoneButtonTint,
                isInteractive: viewModel.hasAPIKey && !viewModel.isProcessing && !isMicrophoneDragActive
            )
            .scaleEffect(viewModel.isPushToTalkRecording && !isMicrophoneDragActive ? 1.08 : 1)
            .shadow(
                color: microphoneButtonTint.opacity(isMicrophoneDragActive ? 0.14 : 0.34),
                radius: isMicrophoneDragActive ? 9 : 18,
                x: 0,
                y: 0
            )
            .shadow(
                color: microphoneButtonTint.opacity(isMicrophoneDragActive ? 0.08 : 0.2),
                radius: isMicrophoneDragActive ? 4 : 7,
                x: 0,
                y: 2
            )
            .shadow(color: .black.opacity(0.28), radius: 8, x: 0, y: 3)
            .animation(.easeInOut(duration: 0.14), value: viewModel.isPushToTalkRecording)
            .animation(.easeInOut(duration: 0.18), value: viewModel.isProcessing)
            .contentShape(Capsule(style: .continuous))
            .allowsHitTesting(viewModel.hasAPIKey && !viewModel.isProcessing)
            .accessibilityLabel(microphoneAccessibilityLabel)
            .accessibilityAddTraits(.isButton)
    }

    private var microphoneAccessibilityLabel: String {
        if viewModel.isProcessing {
            return "Processing"
        }

        if viewModel.isRecordingLocked {
            return "Locked recording"
        }

        return "Microphone"
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

    private func microphoneDragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                handleMicrophoneDragChanged(value, in: size)
            }
            .onEnded { value in
                handleMicrophoneDragEnded(value, in: size)
            }
    }

    private func handleMicrophoneDragChanged(_ value: DragGesture.Value, in size: CGSize) {
        guard viewModel.hasAPIKey && !viewModel.isProcessing else { return }

        if viewModel.isRecordingLocked {
            guard isMicrophoneDragActive || dragDistance(value.translation) >= lockedDragActivationThreshold else {
                return
            }

            if !isMicrophoneDragActive {
                withAnimation(.easeInOut(duration: 0.12)) {
                    isMicrophoneDragActive = true
                }
            }

            microphoneDragTranslation = value.translation
            activeDragTarget = dragTarget(at: microphonePosition(in: size), in: size, includeLock: false)
            return
        }

        if !isMicrophoneDragActive {
            guard viewModel.canBeginRecording else { return }

            hasPressedMicrophone = true
            withAnimation(.easeInOut(duration: 0.12)) {
                isMicrophoneDragActive = true
            }
            viewModel.beginPushToTalkRecording()
        }

        microphoneDragTranslation = value.translation
        activeDragTarget = dragTarget(at: microphonePosition(in: size), in: size, includeLock: true)
    }

    private func handleMicrophoneDragEnded(_ value: DragGesture.Value, in size: CGSize) {
        if viewModel.isRecordingLocked {
            guard isMicrophoneDragActive else {
                viewModel.finishLockedPushToTalkRecording()
                return
            }

            microphoneDragTranslation = value.translation
            if dragTarget(at: microphonePosition(in: size), in: size, includeLock: false) == .cancel {
                viewModel.cancelPushToTalkRecording()
            }

            resetMicrophoneDrag()
            return
        }

        guard isMicrophoneDragActive else { return }

        microphoneDragTranslation = value.translation
        let target = dragTarget(at: microphonePosition(in: size), in: size, includeLock: true)

        switch target {
        case .lock:
            viewModel.lockPushToTalkRecording()
        case .cancel:
            viewModel.cancelPushToTalkRecording()
        case nil:
            viewModel.endPushToTalkRecording()
        }

        resetMicrophoneDrag()
    }

    private func resetMicrophoneDrag() {
        withAnimation(.spring(response: 0.22, dampingFraction: 0.78)) {
            isMicrophoneDragActive = false
            microphoneDragTranslation = .zero
            activeDragTarget = nil
        }
    }

    private func microphoneHomePosition(in size: CGSize) -> CGPoint {
        CGPoint(
            x: size.width - microphoneHomeTrailing - microphoneButtonSize.width / 2,
            y: size.height - microphoneHomeBottom - microphoneButtonSize.height / 2
        )
    }

    private func microphonePosition(in size: CGSize) -> CGPoint {
        let homePosition = microphoneHomePosition(in: size)

        guard isMicrophoneDragActive else {
            return homePosition
        }

        return clampedMicrophonePosition(
            CGPoint(
                x: homePosition.x + microphoneDragTranslation.width,
                y: homePosition.y + microphoneDragTranslation.height
            ),
            in: size
        )
    }

    private func clampedMicrophonePosition(_ position: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(position.x, microphoneButtonSize.width / 2), size.width - microphoneButtonSize.width / 2),
            y: min(max(position.y, microphoneButtonSize.height / 2), size.height - microphoneButtonSize.height / 2)
        )
    }

    private func dragDistance(_ translation: CGSize) -> CGFloat {
        hypot(translation.width, translation.height)
    }

    private func dragTarget(at point: CGPoint, in size: CGSize, includeLock: Bool) -> PTTDragTarget? {
        if includeLock,
           dragTargetFrame(.lock, in: size)
            .insetBy(dx: -dragTargetHitPadding, dy: -dragTargetHitPadding)
            .contains(point) {
            return .lock
        }

        if dragTargetFrame(.cancel, in: size)
            .insetBy(dx: -dragTargetHitPadding, dy: -dragTargetHitPadding)
            .contains(point) {
            return .cancel
        }

        return nil
    }

    private func dragTargetFrame(_ target: PTTDragTarget, in size: CGSize) -> CGRect {
        switch target {
        case .lock:
            let centerX = microphoneHomePosition(in: size).x
            return CGRect(
                x: min(
                    max(dragTargetEdgeInset, centerX - dragTargetSize.width / 2),
                    size.width - dragTargetSize.width - dragTargetEdgeInset
                ),
                y: lockTargetTopInset,
                width: dragTargetSize.width,
                height: dragTargetSize.height
            )
        case .cancel:
            let centerY = microphoneHomePosition(in: size).y
            return CGRect(
                x: cancelTargetLeadingInset,
                y: min(
                    max(dragTargetEdgeInset, centerY - dragTargetSize.height / 2),
                    size.height - dragTargetSize.height - dragTargetEdgeInset
                ),
                width: dragTargetSize.width,
                height: dragTargetSize.height
            )
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo(bottomID, anchor: .bottom)
        }
    }
}

private enum PTTDragTarget {
    case lock
    case cancel

    var symbolName: String {
        switch self {
        case .lock:
            return "lock.fill"
        case .cancel:
            return "trash.fill"
        }
    }

    var tint: Color {
        switch self {
        case .lock:
            return Color(red: 0.07, green: 0.46, blue: 1)
        case .cancel:
            return Color(red: 1, green: 0.12, blue: 0.18)
        }
    }
}

private struct CurvedPromptArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let start = CGPoint(x: rect.minX + rect.width * 0.15, y: rect.minY + rect.height * 0.18)
        let end = CGPoint(x: rect.minX + rect.width * 0.78, y: rect.minY + rect.height * 0.69)

        path.move(to: start)
        path.addCurve(
            to: end,
            control1: CGPoint(x: start.x - rect.width * 0.02, y: rect.minY + rect.height * 0.72),
            control2: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.minY + rect.height * 0.74)
        )

        path.move(to: CGPoint(x: end.x - rect.width * 0.15, y: end.y - rect.height * 0.07))
        path.addLine(to: end)
        path.addLine(to: CGPoint(x: end.x - rect.width * 0.15, y: end.y + rect.height * 0.07))

        return path
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
