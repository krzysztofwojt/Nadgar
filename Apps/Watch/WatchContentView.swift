import SwiftUI
import WristAssistShared

struct WatchContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = WatchVoiceViewModel()
    @State private var isMicrophoneDragActive = false
    @State private var microphoneDragTranslation: CGSize = .zero
    @State private var activeDragTarget: PTTDragTarget?
    @State private var hasPressedMicrophone = false
    @State private var isChatScrolledAwayFromBottom = false
    @State private var isProgrammaticallyScrollingToBottom = false
    @State private var suppressedScrolledAwayState = false
    @State private var scrollToBottomSuppressionGeneration = 0
    @State private var assistantResponseTopFocusID: UUID?
    @State private var assistantResponseTopLockID: UUID?
    @State private var selectedCitation: ChatCitation?
    @State private var citationOpenFailure: String?
    private let bottomID = "chat-bottom"
    private let chatScrollCoordinateSpace = "watch-chat-scroll"
    private let chatTopReadableInset: CGFloat = 46
    private let chatBottomReadableInset: CGFloat = 78
    private let chatAccentColor = Color(red: 0.07, green: 0.46, blue: 1)
    private let microphoneButtonSize = CGSize(width: 66, height: 44)
    private let scrollToBottomButtonSize: CGFloat = 38
    private let scrollToBottomButtonLeading: CGFloat = 10
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
        .alert("Source", isPresented: isSelectedCitationPresented) {
            Button("Open on iPhone") {
                if let selectedCitation {
                    openCitationOnPhone(selectedCitation)
                }
            }

            Button("Close", role: .cancel) {}
        } message: {
            Text(selectedCitation?.displayTitle ?? "")
        }
        .alert("Could not open on iPhone", isPresented: isCitationOpenFailurePresented) {
            Button("Close", role: .cancel) {}
        } message: {
            Text(citationOpenFailure ?? "")
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
                        VStack(spacing: 8) {
                            ForEach(viewModel.messages) { message in
                                messageBubble(message)
                                    .background {
                                        if message.id == assistantResponseTopFocusID {
                                            GeometryReader { messageProxy in
                                                Color.clear
                                                    .preference(
                                                        key: AssistantResponseFramePreferenceKey.self,
                                                        value: messageProxy.frame(in: .named(chatScrollCoordinateSpace))
                                                    )
                                            }
                                        }
                                    }
                                    .id(message.id)
                            }

                            Color.clear
                                .frame(height: chatBottomReadableInset)
                                .background {
                                    GeometryReader { bottomProxy in
                                        Color.clear
                                            .preference(
                                                key: ChatBottomYPreferenceKey.self,
                                                value: bottomProxy.frame(in: .named(chatScrollCoordinateSpace)).maxY
                                            )
                                    }
                                }
                                .id(bottomID)
                        }
                        .padding(.horizontal, 8)
                        .padding(.top, 6)
                        .frame(minHeight: geometry.size.height, alignment: .bottom)
                    }
                    .contentMargins(.top, chatTopReadableInset, for: .scrollContent)
                    .scrollIndicators(.hidden)
                    .coordinateSpace(name: chatScrollCoordinateSpace)
                    .onPreferenceChange(ChatBottomYPreferenceKey.self) { bottomY in
                        updateScrolledAwayState(bottomY: bottomY, viewportHeight: geometry.size.height)
                    }
                    .onPreferenceChange(AssistantResponseFramePreferenceKey.self) { frame in
                        followAssistantResponseIfNeeded(frame: frame, proxy: proxy)
                    }
                    .onAppear {
                        scrollToBottom(proxy, hideIndicatorDuringScroll: true)
                    }
                    .onChange(of: viewModel.messages) { oldMessages, newMessages in
                        scrollForMessageChange(from: oldMessages, to: newMessages, proxy: proxy)
                    }
                    .onChange(of: viewModel.pttState) { _, newState in
                        if newState == .recording {
                            assistantResponseTopFocusID = nil
                            assistantResponseTopLockID = nil
                        }

                        if newState == .ready {
                            assistantResponseTopFocusID = nil
                            assistantResponseTopLockID = nil
                        }

                        if newState != .ready {
                            scrollToBottom(proxy, hideIndicatorDuringScroll: true)
                        }

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
                        recordingDragScrim
                    }

                    if isMicrophoneDragActive {
                        dragTargetsOverlay(in: geometry.size)
                    }

                    if shouldShowScrollToBottomButton {
                        scrollToBottomButton {
                            assistantResponseTopFocusID = nil
                            assistantResponseTopLockID = nil
                            scrollToBottom(proxy, hideIndicatorDuringScroll: true)
                        }
                        .position(scrollToBottomButtonPosition(in: geometry.size))
                        .transition(.opacity.combined(with: .scale(scale: 0.86)))
                        .zIndex(2)
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
            let renderedMessage = renderedMessageText(for: message)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(renderedMessage.segments.indices, id: \.self) { index in
                    messageTextSegment(renderedMessage.segments[index])
                }

                if message.role == .assistant && renderedMessage.sourceCount > 0 {
                    sourceBadge(sourceCount: renderedMessage.sourceCount)
                }
            }
            .environment(\.openURL, OpenURLAction { url in
                if message.role == .assistant {
                    selectCitation(for: url, in: message)
                }
                return .handled
            })
        }
    }

    @ViewBuilder
    private func messageTextSegment(_ segment: RenderedMessageSegment) -> some View {
        switch segment.kind {
        case .body:
            Text(segment.text)
                .font(.system(size: 13, weight: .medium))
                .lineSpacing(1)
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
        case .heading:
            Text(segment.text)
                .font(.system(size: 14, weight: .semibold))
                .lineSpacing(1)
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
        case .blockquote:
            Text(segment.text)
                .font(.system(size: 13, weight: .medium))
                .lineSpacing(1)
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        case .codeBlock:
            Text(segment.text)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .lineSpacing(1)
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        case .horizontalRule:
            Rectangle()
                .fill(Color.white.opacity(0.24))
                .frame(height: 1)
                .padding(.vertical, 3)
        case .table:
            if let table = segment.table {
                markdownTable(table)
            }
        }
    }

    private func markdownTable(_ table: RenderedMarkdownTable) -> some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(table.rows.indices, id: \.self) { rowIndex in
                    let row = table.rows[rowIndex]

                    HStack(alignment: .top, spacing: 0) {
                        ForEach(row.cells.indices, id: \.self) { cellIndex in
                            markdownTableCell(row.cells[cellIndex], isHeader: row.isHeader)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Markdown table")
    }

    private func markdownTableCell(_ text: AttributedString, isHeader: Bool) -> some View {
        Text(text)
            .font(.system(size: 12, weight: isHeader ? .semibold : .medium))
            .lineSpacing(1)
            .foregroundStyle(.white)
            .multilineTextAlignment(.leading)
            .frame(minWidth: 72, maxWidth: 118, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(isHeader ? Color.white.opacity(0.12) : Color.white.opacity(0.06))
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Color.white.opacity(0.10))
                    .frame(width: 1)
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.white.opacity(0.10))
                    .frame(height: 1)
            }
    }

    private var isCitationOpenFailurePresented: Binding<Bool> {
        Binding {
            citationOpenFailure != nil
        } set: { isPresented in
            if !isPresented {
                citationOpenFailure = nil
            }
        }
    }

    private var isSelectedCitationPresented: Binding<Bool> {
        Binding {
            selectedCitation != nil
        } set: { isPresented in
            if !isPresented {
                selectedCitation = nil
            }
        }
    }

    private func renderedMessageText(for message: ChatMessage) -> RenderedMessageText {
        let displaySegments = watchDisplayMarkdownSegments(from: message.text)
        let displayMarkdown = displaySegments.map(\.markdown).joined(separator: "\n")
        var attributed = markdownAttributedString(from: displayMarkdown)

        if message.role == .assistant {
            applyCitationLinks(to: &attributed, citations: validCitations(for: message), sourceText: message.text)
        }

        let sourceCount = sourceCount(in: attributed)
        styleLinks(in: &attributed)

        return RenderedMessageText(
            segments: renderedSegments(from: attributed, displaySegments: displaySegments),
            sourceCount: sourceCount
        )
    }

    private func watchDisplayMarkdown(from text: String) -> String {
        watchDisplayMarkdownSegments(from: text)
            .map(\.markdown)
            .joined(separator: "\n")
    }

    private func watchDisplayMarkdownSegments(from text: String) -> [WatchDisplayMarkdownSegment] {
        var segments: [WatchDisplayMarkdownSegment] = []
        var codeBlockLines: [String] = []
        var isInsideCodeBlock = false
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var lineIndex = 0

        while lineIndex < lines.count {
            let line = lines[lineIndex]

            if isInsideCodeBlock {
                if isMarkdownCodeFence(line) {
                    appendDisplayMarkdownSegment(
                        markdown: markdownEscapedPlainText(codeBlockLines.joined(separator: "\n")),
                        kind: .codeBlock,
                        to: &segments
                    )
                    codeBlockLines = []
                    isInsideCodeBlock = false
                } else {
                    codeBlockLines.append(String(line))
                }

                lineIndex += 1
                continue
            }

            if isMarkdownCodeFence(line) {
                isInsideCodeBlock = true
                lineIndex += 1
                continue
            }

            if let tableResult = markdownTableSegment(startingAt: lineIndex, in: lines) {
                appendDisplayMarkdownSegment(
                    markdown: tableResult.table.displayMarkdown,
                    kind: .table,
                    table: tableResult.table,
                    to: &segments
                )
                lineIndex = tableResult.nextLineIndex
                continue
            }

            let displayLine = watchDisplayMarkdownLine(from: Substring(line))
            appendDisplayMarkdownSegment(
                markdown: displayLine.markdown,
                kind: displayLine.kind,
                to: &segments
            )

            lineIndex += 1
        }

        if isInsideCodeBlock {
            appendDisplayMarkdownSegment(
                markdown: markdownEscapedPlainText(codeBlockLines.joined(separator: "\n")),
                kind: .codeBlock,
                to: &segments
            )
        }

        return segments
    }

    private func appendDisplayMarkdownSegment(
        markdown: String,
        kind: RenderedMessageSegmentKind,
        table: WatchDisplayMarkdownTable? = nil,
        to segments: inout [WatchDisplayMarkdownSegment]
    ) {
        if let lastSegment = segments.last,
           lastSegment.kind == kind,
           lastSegment.table == nil,
           table == nil,
           kind.canMergeAdjacentLines {
            segments[segments.count - 1].markdown += "\n\(markdown)"
        } else {
            segments.append(
                WatchDisplayMarkdownSegment(
                    markdown: markdown,
                    kind: kind,
                    table: table
                )
            )
        }
    }

    private func watchDisplayMarkdownLine(from line: Substring) -> WatchDisplayMarkdownLine {
        var index = line.startIndex
        var consumedIndentation = 0

        while index < line.endIndex,
              consumedIndentation < 3,
              line[index] == " " {
            consumedIndentation += 1
            index = line.index(after: index)
        }

        if isMarkdownHorizontalRule(line) {
            return WatchDisplayMarkdownLine(markdown: " ", kind: .horizontalRule)
        }

        if let headingText = markdownHeadingText(in: line, from: index) {
            return WatchDisplayMarkdownLine(markdown: headingText, kind: .heading)
        }

        guard index < line.endIndex,
              line[index] == ">"
        else {
            return WatchDisplayMarkdownLine(markdown: String(line), kind: .body)
        }

        index = line.index(after: index)

        if index < line.endIndex,
           line[index] == " " {
            index = line.index(after: index)
        }

        return WatchDisplayMarkdownLine(markdown: String(line[index...]), kind: .blockquote)
    }

    private func isMarkdownCodeFence(_ line: Substring) -> Bool {
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
        return trimmedLine.hasPrefix("```") || trimmedLine.hasPrefix("~~~")
    }

    private func isMarkdownHorizontalRule(_ line: Substring) -> Bool {
        let compactLine = line.filter { !$0.isWhitespace }
        guard compactLine.count >= 3,
              let marker = compactLine.first,
              marker == "-" || marker == "*" || marker == "_"
        else {
            return false
        }

        return compactLine.allSatisfy { $0 == marker }
    }

    private func markdownTableSegment(
        startingAt lineIndex: Int,
        in lines: [Substring]
    ) -> (table: WatchDisplayMarkdownTable, nextLineIndex: Int)? {
        guard lineIndex + 1 < lines.count,
              let headerCells = markdownTableCells(in: lines[lineIndex]),
              headerCells.count >= 2,
              isMarkdownTableSeparator(lines[lineIndex + 1], columnCount: headerCells.count)
        else {
            return nil
        }

        var rows = [headerCells]
        var nextLineIndex = lineIndex + 2

        while nextLineIndex < lines.count,
              let cells = markdownTableCells(in: lines[nextLineIndex]) {
            rows.append(normalizedMarkdownTableCells(cells, columnCount: headerCells.count))
            nextLineIndex += 1
        }

        return (
            table: WatchDisplayMarkdownTable(rows: rows),
            nextLineIndex: nextLineIndex
        )
    }

    private func markdownTableCells(in line: Substring) -> [String]? {
        var tableLine = String(line).trimmingCharacters(in: .whitespaces)
        guard tableLine.contains("|") else { return nil }

        if tableLine.first == "|" {
            tableLine.removeFirst()
        }

        if tableLine.last == "|" {
            tableLine.removeLast()
        }

        let cells = tableLine
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        guard cells.count >= 2 else { return nil }
        return cells
    }

    private func normalizedMarkdownTableCells(_ cells: [String], columnCount: Int) -> [String] {
        if cells.count == columnCount {
            return cells
        }

        if cells.count > columnCount {
            return Array(cells.prefix(columnCount))
        }

        return cells + Array(repeating: "", count: columnCount - cells.count)
    }

    private func isMarkdownTableSeparator(_ line: Substring, columnCount: Int) -> Bool {
        guard let cells = markdownTableCells(in: line),
              cells.count == columnCount
        else {
            return false
        }

        return cells.allSatisfy(isMarkdownTableSeparatorCell)
    }

    private func isMarkdownTableSeparatorCell(_ cell: String) -> Bool {
        let compactCell = cell.filter { !$0.isWhitespace }
        let dashCount = compactCell.filter { $0 == "-" }.count

        guard dashCount >= 3 else { return false }

        return compactCell.allSatisfy { character in
            character == "-" || character == ":"
        }
    }

    private func markdownHeadingText(in line: Substring, from startIndex: Substring.Index) -> String? {
        var index = startIndex
        var markerCount = 0

        while index < line.endIndex,
              markerCount < 6,
              line[index] == "#" {
            markerCount += 1
            index = line.index(after: index)
        }

        guard markerCount > 0,
              index < line.endIndex,
              line[index] == " "
        else {
            return nil
        }

        return String(line[line.index(after: index)...])
    }

    private func markdownEscapedPlainText(_ text: String) -> String {
        var escapedText = ""
        let markdownControlCharacters = Set("\\`*_{}[]<>()#+-.!|")

        for character in text {
            if markdownControlCharacters.contains(character) {
                escapedText.append("\\")
            }

            escapedText.append(character)
        }

        return escapedText
    }

    private func markdownAttributedString(from text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    private func renderedSegments(
        from attributed: AttributedString,
        displaySegments: [WatchDisplayMarkdownSegment]
    ) -> [RenderedMessageSegment] {
        var renderedSegments: [RenderedMessageSegment] = []
        var nextOffset = 0

        for (index, displaySegment) in displaySegments.enumerated() {
            let visibleLength = markdownAttributedString(from: displaySegment.markdown).characters.count

            if let range = attributedRange(
                in: attributed,
                lowerOffset: nextOffset,
                upperOffset: nextOffset + visibleLength
            ) {
                renderedSegments.append(
                    renderedSegment(
                        from: AttributedString(attributed[range]),
                        kind: displaySegment.kind,
                        table: displaySegment.table
                    )
                )
            }

            nextOffset += visibleLength

            if index < displaySegments.count - 1 {
                nextOffset += 1
            }
        }

        if renderedSegments.isEmpty {
            return [
                renderedSegment(from: attributed, kind: .body)
            ]
        }

        return renderedSegments
    }

    private func renderedSegment(
        from attributed: AttributedString,
        kind: RenderedMessageSegmentKind,
        table: WatchDisplayMarkdownTable? = nil
    ) -> RenderedMessageSegment {
        if let table {
            return RenderedMessageSegment(
                text: attributed,
                kind: kind,
                table: renderedMarkdownTable(from: attributed, sourceTable: table)
            )
        }

        var text = attributed
        appendLinkMarkers(to: &text)
        return RenderedMessageSegment(text: text, kind: kind)
    }

    private func renderedMarkdownTable(
        from attributed: AttributedString,
        sourceTable: WatchDisplayMarkdownTable
    ) -> RenderedMarkdownTable {
        var rowOffset = 0
        var rows: [RenderedMarkdownTableRow] = []

        for (rowIndex, sourceRow) in sourceTable.rows.enumerated() {
            var cellOffset = rowOffset
            var cells: [AttributedString] = []

            for (cellIndex, cellMarkdown) in sourceRow.enumerated() {
                let cellLength = markdownAttributedString(from: cellMarkdown).characters.count

                if let range = attributedRange(
                    in: attributed,
                    lowerOffset: cellOffset,
                    upperOffset: cellOffset + cellLength
                ) {
                    var cellText = AttributedString(attributed[range])
                    appendLinkMarkers(to: &cellText)
                    cells.append(cellText)
                } else {
                    var fallbackText = markdownAttributedString(from: cellMarkdown)
                    appendLinkMarkers(to: &fallbackText)
                    cells.append(fallbackText)
                }

                cellOffset += cellLength

                if cellIndex < sourceRow.count - 1 {
                    cellOffset += 1
                }
            }

            rows.append(
                RenderedMarkdownTableRow(
                    cells: cells,
                    isHeader: rowIndex == 0
                )
            )

            rowOffset = cellOffset

            if rowIndex < sourceTable.rows.count - 1 {
                rowOffset += 1
            }
        }

        return RenderedMarkdownTable(rows: rows)
    }

    private func applyCitationLinks(
        to attributed: inout AttributedString,
        citations: [ChatCitation],
        sourceText: String
    ) {
        var nextVisibleSearchOffset = 0

        for citation in citations {
            guard let url = URL(string: citation.url),
                  let range = citationVisibleRange(
                    for: citation,
                    sourceText: sourceText,
                    attributed: attributed,
                    minimumVisibleOffset: nextVisibleSearchOffset
                  )
            else {
                continue
            }

            attributed[range].link = url
            nextVisibleSearchOffset = attributed.characters.distance(from: attributed.startIndex, to: range.upperBound)
        }
    }

    private func citationVisibleRange(
        for citation: ChatCitation,
        sourceText: String,
        attributed: AttributedString,
        minimumVisibleOffset: Int
    ) -> Range<AttributedString.Index>? {
        if let renderedRange = renderedCitationRange(
            for: citation,
            sourceText: sourceText,
            attributed: attributed,
            minimumVisibleOffset: minimumVisibleOffset
        ) {
            return renderedRange
        }

        return offsetCitationRange(for: citation, attributed: attributed)
    }

    private func renderedCitationRange(
        for citation: ChatCitation,
        sourceText: String,
        attributed: AttributedString,
        minimumVisibleOffset: Int
    ) -> Range<AttributedString.Index>? {
        guard let sourceRange = stringRange(
            in: sourceText,
            startOffset: citation.startIndex,
            endOffset: citation.endIndex
        ) else {
            return nil
        }

        let rawCitationText = String(sourceText[sourceRange])
        let displayCitationText = watchDisplayMarkdown(from: rawCitationText)
        let visibleCitationText = String(markdownAttributedString(from: displayCitationText).characters)
        guard !visibleCitationText.isEmpty else {
            return nil
        }

        let visibleText = String(attributed.characters)
        guard !visibleText.isEmpty else {
            return nil
        }

        let preferredVisibleOffset = visibleOffset(
            forSourceOffset: citation.startIndex,
            sourceText: sourceText
        ) ?? minimumVisibleOffset

        guard let range = bestVisibleRange(
            matching: visibleCitationText,
            in: visibleText,
            preferredOffset: preferredVisibleOffset,
            minimumOffset: minimumVisibleOffset
        )
        else {
            return nil
        }

        return attributedRange(
            in: attributed,
            lowerOffset: visibleText.distance(from: visibleText.startIndex, to: range.lowerBound),
            upperOffset: visibleText.distance(from: visibleText.startIndex, to: range.upperBound)
        )
    }

    private func visibleOffset(forSourceOffset sourceOffset: Int, sourceText: String) -> Int? {
        guard sourceOffset >= 0,
              sourceOffset <= sourceText.count
        else {
            return nil
        }

        let prefixEnd = sourceText.index(sourceText.startIndex, offsetBy: sourceOffset)
        let displayPrefix = watchDisplayMarkdown(from: String(sourceText[..<prefixEnd]))
        return markdownAttributedString(from: displayPrefix).characters.count
    }

    private func bestVisibleRange(
        matching text: String,
        in visibleText: String,
        preferredOffset: Int,
        minimumOffset: Int
    ) -> Range<String.Index>? {
        var matches: [(range: Range<String.Index>, lowerOffset: Int)] = []
        var searchStart = visibleText.startIndex

        while searchStart < visibleText.endIndex,
              let range = visibleText.range(of: text, range: searchStart..<visibleText.endIndex) {
            let lowerOffset = visibleText.distance(from: visibleText.startIndex, to: range.lowerBound)
            matches.append((range, lowerOffset))
            searchStart = range.upperBound
        }

        let eligibleMatches = matches.filter { $0.lowerOffset >= minimumOffset }
        let candidates = eligibleMatches.isEmpty ? matches : eligibleMatches
        return candidates.min { lhs, rhs in
            let lhsDistance = abs(lhs.lowerOffset - preferredOffset)
            let rhsDistance = abs(rhs.lowerOffset - preferredOffset)
            guard lhsDistance != rhsDistance else {
                return lhs.lowerOffset < rhs.lowerOffset
            }

            return lhsDistance < rhsDistance
        }?.range
    }

    private func offsetCitationRange(
        for citation: ChatCitation,
        attributed: AttributedString
    ) -> Range<AttributedString.Index>? {
        attributedRange(
            in: attributed,
            lowerOffset: citation.startIndex,
            upperOffset: citation.endIndex
        )
    }

    private func attributedRange(
        in attributed: AttributedString,
        lowerOffset: Int,
        upperOffset: Int
    ) -> Range<AttributedString.Index>? {
        let visibleTextLength = attributed.characters.count
        guard lowerOffset >= 0,
              upperOffset > lowerOffset,
              upperOffset <= visibleTextLength
        else {
            return nil
        }

        let start = attributed.characters.index(attributed.startIndex, offsetBy: lowerOffset)
        let end = attributed.characters.index(attributed.startIndex, offsetBy: upperOffset)
        return start..<end
    }

    private func stringRange(
        in text: String,
        startOffset: Int,
        endOffset: Int
    ) -> Range<String.Index>? {
        guard startOffset >= 0,
              endOffset > startOffset,
              endOffset <= text.count
        else {
            return nil
        }

        let start = text.index(text.startIndex, offsetBy: startOffset)
        let end = text.index(text.startIndex, offsetBy: endOffset)
        return start..<end
    }

    private func styleLinks(in attributed: inout AttributedString) {
        for run in attributed.runs {
            guard run.link != nil else { continue }
            attributed[run.range].foregroundColor = .white
            attributed[run.range].underlineStyle = Text.LineStyle(pattern: .solid, color: .white)
        }
    }

    private func appendLinkMarkers(to attributed: inout AttributedString) {
        let markers = attributed.runs.compactMap { run -> LinkMarker? in
            guard let url = run.link else { return nil }
            let upperOffset = attributed.characters.distance(from: attributed.startIndex, to: run.range.upperBound)
            return LinkMarker(upperOffset: upperOffset, url: url)
        }

        for marker in markers.reversed() {
            let insertIndex = attributed.characters.index(attributed.startIndex, offsetBy: marker.upperOffset)
            attributed.insert(sourceMarkerAttributedString(url: marker.url), at: insertIndex)
        }
    }

    private func sourceMarkerAttributedString(url: URL) -> AttributedString {
        var marker = AttributedString("\u{00A0}\u{1F310}\u{FE0E}")
        marker.link = url
        marker.foregroundColor = .white
        marker.font = .system(size: 9, weight: .semibold)
        return marker
    }

    private func sourceCount(in attributed: AttributedString) -> Int {
        var urls = Set<String>()

        for run in attributed.runs {
            if let url = run.link {
                urls.insert(url.absoluteString)
            }
        }

        return urls.count
    }

    private func validCitations(for message: ChatMessage) -> [ChatCitation] {
        var nextAvailableOffset = 0
        var citations: [ChatCitation] = []
        let textLength = message.text.count

        for citation in message.citations.sorted(by: { $0.startIndex < $1.startIndex }) {
            guard citation.startIndex >= nextAvailableOffset,
                  citation.endIndex > citation.startIndex,
                  citation.endIndex <= textLength
            else {
                continue
            }

            citations.append(citation)
            nextAvailableOffset = citation.endIndex
        }

        return citations
    }

    private func sourceBadge(sourceCount: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "globe")
                .font(.system(size: 9, weight: .semibold))

            Text(sourceCount == 1 ? "1 source" : "\(sourceCount) sources")
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(.white.opacity(0.68))
        .accessibilityLabel(sourceCount == 1 ? "1 web source" : "\(sourceCount) web sources")
    }

    private func selectCitation(for url: URL, in message: ChatMessage) {
        selectedCitation = message.citations.first { citation in
            guard let citationURL = URL(string: citation.url) else {
                return citation.url == url.absoluteString
            }

            return citationURL.absoluteString == url.absoluteString
        } ?? ChatCitation(
            startIndex: 0,
            endIndex: 0,
            url: url.absoluteString,
            title: url.host() ?? "Source"
        )
    }

    private func openCitationOnPhone(_ citation: ChatCitation) {
        Task {
            let failure = await viewModel.openCitationOnPhone(citation)
            await MainActor.run {
                citationOpenFailure = failure
            }
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

    private var shouldShowScrollToBottomButton: Bool {
        isChatScrolledAwayFromBottom &&
            !viewModel.messages.isEmpty &&
            !isMicrophoneDragActive &&
            !viewModel.isPushToTalkRecording
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

    private func scrollToBottomButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: scrollToBottomButtonSize, height: scrollToBottomButtonSize)
        }
        .buttonStyle(.plain)
        .pttGlassButton(tint: .white, isInteractive: true)
        .shadow(color: .white.opacity(0.22), radius: 10, x: 0, y: 0)
        .shadow(color: .black.opacity(0.28), radius: 8, x: 0, y: 3)
        .contentShape(Circle())
        .accessibilityLabel("Scroll to latest message")
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

            dragTargetHints(in: size, lockFrame: lockFrame, cancelFrame: cancelFrame)
        }
        .frame(width: size.width, height: size.height)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
        .animation(.easeInOut(duration: 0.14), value: activeDragTarget)
        .allowsHitTesting(false)
    }

    private var recordingDragScrim: some View {
        ZStack {
            Color.black.opacity(0.54)

            RadialGradient(
                colors: [
                    Color.black.opacity(0),
                    Color.black.opacity(0.34)
                ],
                center: .center,
                startRadius: 32,
                endRadius: 132
            )
        }
        .ignoresSafeArea()
        .transition(.opacity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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

    private func dragTargetHints(in size: CGSize, lockFrame: CGRect, cancelFrame: CGRect) -> some View {
        let lockLabelPosition = CGPoint(
            x: size.width / 2,
            y: size.height * 0.43
        )
        let cancelLabelPosition = CGPoint(
            x: size.width / 2,
            y: size.height * 0.58
        )

        return ZStack {
            if !viewModel.isRecordingLocked {
                dragRoundedCornerInstructionArrow(
                    from: CGPoint(x: lockLabelPosition.x + 29, y: lockLabelPosition.y),
                    to: CGPoint(x: lockFrame.midX, y: lockFrame.midY + 28),
                    cornerRadius: 18,
                    tint: PTTDragTarget.lock.tint,
                    isActive: activeDragTarget == .lock
                )

                dragInstructionLabel(
                    "Lock",
                    tint: PTTDragTarget.lock.tint,
                    isActive: activeDragTarget == .lock
                )
                .position(lockLabelPosition)
            }

            dragRoundedCornerInstructionArrow(
                from: CGPoint(x: cancelLabelPosition.x - 34, y: cancelLabelPosition.y),
                to: CGPoint(x: cancelFrame.midX + 7, y: cancelFrame.midY - 32),
                cornerRadius: 18,
                tint: PTTDragTarget.cancel.tint,
                isActive: activeDragTarget == .cancel
            )

            dragInstructionLabel(
                "Cancel",
                tint: PTTDragTarget.cancel.tint,
                isActive: activeDragTarget == .cancel
            )
            .position(cancelLabelPosition)
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
    }

    private func dragInstructionLabel(_ text: String, tint: Color, isActive: Bool) -> some View {
        Text(text)
            .font(.system(size: isActive ? 16 : 15, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(isActive ? 1 : 0.9))
            .shadow(color: .black.opacity(1), radius: 13, x: 0, y: 3)
            .shadow(color: .black.opacity(0.92), radius: 5, x: 0, y: 2)
            .shadow(color: .black.opacity(0.82), radius: 2, x: 0, y: 1)
            .shadow(color: tint.opacity(isActive ? 0.46 : 0.22), radius: isActive ? 8 : 5, x: 0, y: 0)
            .opacity(activeDragTarget == nil || isActive ? 1 : 0.58)
            .scaleEffect(isActive ? 1.04 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 0.7), value: isActive)
    }

    private func dragRoundedCornerInstructionArrow(
        from start: CGPoint,
        to end: CGPoint,
        cornerRadius: CGFloat,
        tint: Color,
        isActive: Bool
    ) -> some View {
        roundedCornerArrowPath(from: start, to: end, cornerRadius: cornerRadius)
            .stroke(
                tint.opacity(isActive ? 0.96 : 0.72),
                style: StrokeStyle(lineWidth: isActive ? 2.4 : 2, lineCap: .round, lineJoin: .round)
            )
            .shadow(color: tint.opacity(isActive ? 0.56 : 0.24), radius: isActive ? 8 : 4, x: 0, y: 0)
            .opacity(activeDragTarget == nil || isActive ? 1 : 0.62)
            .animation(.spring(response: 0.18, dampingFraction: 0.7), value: isActive)
    }

    private func roundedCornerArrowPath(from start: CGPoint, to end: CGPoint, cornerRadius: CGFloat) -> Path {
        var path = Path()
        let radius = min(cornerRadius, max(abs(start.x - end.x) - 2, 0), max(abs(end.y - start.y) - 2, 0))
        let horizontalDirection: CGFloat = end.x >= start.x ? 1 : -1
        let verticalDirection: CGFloat = end.y >= start.y ? 1 : -1
        let horizontalEnd = CGPoint(x: end.x - horizontalDirection * radius, y: start.y)
        let verticalStart = CGPoint(x: end.x, y: start.y + verticalDirection * radius)

        path.move(to: start)
        path.addLine(to: horizontalEnd)
        path.addQuadCurve(to: verticalStart, control: CGPoint(x: end.x, y: start.y))
        path.addLine(to: end)

        let arrowLength: CGFloat = 9
        let arrowWidth: CGFloat = 5
        path.move(to: CGPoint(x: end.x - arrowWidth, y: end.y - verticalDirection * arrowLength))
        path.addLine(to: end)
        path.addLine(to: CGPoint(x: end.x + arrowWidth, y: end.y - verticalDirection * arrowLength))

        return path
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

    private func scrollToBottomButtonPosition(in size: CGSize) -> CGPoint {
        CGPoint(
            x: scrollToBottomButtonLeading + scrollToBottomButtonSize / 2,
            y: microphoneHomePosition(in: size).y
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

    private func scrollForMessageChange(
        from oldMessages: [ChatMessage],
        to newMessages: [ChatMessage],
        proxy: ScrollViewProxy
    ) {
        if let assistantPlaceholderID = assistantPlaceholderAddedID(from: oldMessages, to: newMessages) {
            assistantResponseTopFocusID = assistantPlaceholderID
            assistantResponseTopLockID = nil
            scrollToBottom(proxy, hideIndicatorDuringScroll: true)
            return
        }

        if let assistantMessageID = assistantResponseReadyID(from: oldMessages, to: newMessages) {
            assistantResponseTopFocusID = assistantMessageID
            assistantResponseTopLockID = nil
            scrollToBottom(proxy, hideIndicatorDuringScroll: true)
            return
        }

        if isAssistantResponseStreamingUpdate(from: oldMessages, to: newMessages) {
            return
        }

        if newMessages.last?.role != .assistant {
            assistantResponseTopFocusID = nil
            assistantResponseTopLockID = nil
        }

        scrollToBottom(proxy, hideIndicatorDuringScroll: true)
    }

    private func assistantPlaceholderAddedID(from oldMessages: [ChatMessage], to newMessages: [ChatMessage]) -> UUID? {
        guard newMessages.count > oldMessages.count else { return nil }

        for newMessage in newMessages.reversed() where newMessage.role == .assistant && newMessage.isPlaceholder {
            guard !oldMessages.contains(where: { $0.id == newMessage.id }) else { continue }
            return newMessage.id
        }

        return nil
    }

    private func assistantResponseReadyID(from oldMessages: [ChatMessage], to newMessages: [ChatMessage]) -> UUID? {
        for newMessage in newMessages.reversed() where newMessage.role == .assistant && !newMessage.isPlaceholder {
            guard let oldMessage = oldMessages.first(where: { $0.id == newMessage.id }) else {
                if newMessages.count > oldMessages.count {
                    return newMessage.id
                }

                continue
            }

            if oldMessage.role == .assistant && oldMessage.isPlaceholder {
                return newMessage.id
            }
        }

        return nil
    }

    private func isAssistantResponseStreamingUpdate(from oldMessages: [ChatMessage], to newMessages: [ChatMessage]) -> Bool {
        guard oldMessages.count == newMessages.count else { return false }

        let changedMessages = zip(oldMessages, newMessages).filter { oldMessage, newMessage in
            oldMessage != newMessage
        }
        guard changedMessages.count == 1,
              let (oldMessage, newMessage) = changedMessages.first,
              oldMessage.id == newMessage.id,
              oldMessage.role == .assistant,
              newMessage.role == .assistant,
              !oldMessage.isPlaceholder,
              !newMessage.isPlaceholder
        else {
            return false
        }

        return newMessage.text.hasPrefix(oldMessage.text) ||
            oldMessage.text.hasPrefix(newMessage.text) ||
            oldMessage.citations != newMessage.citations
    }

    private func followAssistantResponseIfNeeded(frame: CGRect?, proxy: ScrollViewProxy) {
        guard let frame,
              let assistantResponseTopFocusID,
              let latestMessage = viewModel.messages.last,
              latestMessage.id == assistantResponseTopFocusID,
              latestMessage.role == .assistant
        else {
            return
        }

        let targetTopY = chatTopReadableInset + 4
        if assistantResponseTopLockID == assistantResponseTopFocusID {
            scrollToAssistantResponseTop(assistantResponseTopFocusID, proxy: proxy, animated: false)
            return
        }

        guard frame.minY > targetTopY + 3 else {
            assistantResponseTopLockID = assistantResponseTopFocusID
            scrollToAssistantResponseTop(assistantResponseTopFocusID, proxy: proxy, animated: true)
            return
        }

        scrollToBottom(proxy, hideIndicatorDuringScroll: true)
    }

    private func scrollToAssistantResponseTop(_ id: UUID, proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(id, anchor: .top)
            }
        } else {
            proxy.scrollTo(id, anchor: .top)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, hideIndicatorDuringScroll: Bool = false) {
        let suppressionGeneration: Int?

        if hideIndicatorDuringScroll {
            isProgrammaticallyScrollingToBottom = true
            isChatScrolledAwayFromBottom = false
            suppressedScrolledAwayState = false
            scrollToBottomSuppressionGeneration += 1
            suppressionGeneration = scrollToBottomSuppressionGeneration
        } else {
            suppressionGeneration = nil
        }

        withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo(bottomID, anchor: .bottom)
        }

        if let suppressionGeneration {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 320_000_000)
                if scrollToBottomSuppressionGeneration == suppressionGeneration {
                    isProgrammaticallyScrollingToBottom = false
                    if suppressedScrolledAwayState {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            isChatScrolledAwayFromBottom = true
                        }
                    }
                }
            }
        }
    }

    private func updateScrolledAwayState(bottomY: CGFloat, viewportHeight: CGFloat) {
        let isAway = bottomY > viewportHeight + 14
        if isProgrammaticallyScrollingToBottom {
            suppressedScrolledAwayState = isAway
            if !isAway {
                isProgrammaticallyScrollingToBottom = false
                suppressedScrolledAwayState = false
            }
            if isChatScrolledAwayFromBottom {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isChatScrolledAwayFromBottom = false
                }
            }
            return
        }

        guard isChatScrolledAwayFromBottom != isAway else { return }

        withAnimation(.easeInOut(duration: 0.16)) {
            isChatScrolledAwayFromBottom = isAway
        }
    }
}

private struct ChatBottomYPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct AssistantResponseFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect?

    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}

private struct RenderedMessageText {
    var segments: [RenderedMessageSegment]
    var sourceCount: Int
}

private struct RenderedMessageSegment {
    var text: AttributedString
    var kind: RenderedMessageSegmentKind
    var table: RenderedMarkdownTable?

    init(
        text: AttributedString,
        kind: RenderedMessageSegmentKind,
        table: RenderedMarkdownTable? = nil
    ) {
        self.text = text
        self.kind = kind
        self.table = table
    }
}

private struct WatchDisplayMarkdownSegment {
    var markdown: String
    var kind: RenderedMessageSegmentKind
    var table: WatchDisplayMarkdownTable?

    init(
        markdown: String,
        kind: RenderedMessageSegmentKind,
        table: WatchDisplayMarkdownTable? = nil
    ) {
        self.markdown = markdown
        self.kind = kind
        self.table = table
    }
}

private struct WatchDisplayMarkdownLine {
    var markdown: String
    var kind: RenderedMessageSegmentKind
}

private enum RenderedMessageSegmentKind: Equatable {
    case body
    case heading
    case blockquote
    case codeBlock
    case horizontalRule
    case table

    var canMergeAdjacentLines: Bool {
        switch self {
        case .body, .blockquote, .codeBlock:
            return true
        case .heading, .horizontalRule, .table:
            return false
        }
    }
}

private struct WatchDisplayMarkdownTable {
    var rows: [[String]]

    var displayMarkdown: String {
        rows
            .map { $0.joined(separator: "\t") }
            .joined(separator: "\n")
    }
}

private struct RenderedMarkdownTable {
    var rows: [RenderedMarkdownTableRow]
}

private struct RenderedMarkdownTableRow {
    var cells: [AttributedString]
    var isHeader: Bool
}

private struct LinkMarker {
    var upperOffset: Int
    var url: URL
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
