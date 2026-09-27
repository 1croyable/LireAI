import SwiftUI
import Combine

private enum MessageRole { case user, assistant }

private struct ChatMessage: Identifiable {
    let id: UUID
    let role: MessageRole
    let text: String?
    var result: LireResult?
    var progressText: String?
    var errorText: String?
}

/// Keeps one lookup conversation alive while its panel is closed.
@MainActor
final class AIReadingConversation: ObservableObject, Identifiable {
    private struct RequestSpec {
        let sequence: Int
        let question: String?
        let nextSource: LireSource?
        let historyUser: String
        let progressText: String
    }

    private struct CompletedTurn {
        let sequence: Int
        let user: String
        let assistant: String
    }

    let id = UUID()
    let source: String
    let sourceFragments: [String]?
    let bookContext: String

    @Published fileprivate var messages: [ChatMessage] = []
    @Published var question = ""
    @Published var sourceExpanded = false
    @Published private(set) var activeRequestCount = 0
    @Published private(set) var activeSearchRequestCount = 0
    @Published private(set) var hasUnreadSearchResult = false

    private var completedTurns: [UUID: CompletedTurn] = [:]
    private var requestTasks: [UUID: Task<Void, Never>] = [:]
    private var activeSearchRequestIDs: Set<UUID> = []
    private var failedRequests: [UUID: RequestSpec] = [:]
    private var nextSequence = 0
    private var started = false
    private var visible = false

    var loading: Bool { activeRequestCount > 0 }
    var hasCompletedAnswer: Bool { !completedTurns.isEmpty }
    var shouldContinueForLookup: Bool { activeSearchRequestCount > 0 || hasUnreadSearchResult }

    init(fragments: [String], bookContext: String) {
        let clean = fragments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        sourceFragments = clean.count > 1 ? clean : nil
        source = clean.joined(separator: " ")
        self.bookContext = bookContext
    }

    func startIfNeeded() {
        guard !started, !source.isEmpty else { return }
        started = true
        launch(question: nil, nextSource: nil, displayText: nil)
    }

    func submitQuestion() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !loading, hasCompletedAnswer else { return }
        question = ""
        launch(question: text, nextSource: nil, displayText: text)
    }

    func appendLookup(fragments: [String]) {
        let selected = LireSource(text: fragments.joined(separator: " "), fragments: fragments)
        guard !selected.text.isEmpty else { return }
        launch(question: nil, nextSource: selected, displayText: selected.text)
    }

    func markVisible() {
        visible = true
        hasUnreadSearchResult = false
    }

    func markHidden() {
        visible = false
    }

    func cancelOutstandingRequest() {
        requestTasks.values.forEach { $0.cancel() }
        requestTasks.removeAll()
        activeSearchRequestIDs.removeAll()
        activeRequestCount = 0
        activeSearchRequestCount = 0
    }

    func retry(_ requestID: UUID) {
        guard let spec = failedRequests.removeValue(forKey: requestID) else { return }
        updateMessage(requestID) {
            $0.errorText = nil
            $0.progressText = spec.progressText
        }
        startTask(requestID: requestID, spec: spec, history: historySnapshot(before: spec.sequence))
    }

    private func launch(question: String?, nextSource: LireSource?, displayText: String?) {
        let requestID = UUID()
        let sequence = nextSequence
        nextSequence += 1

        if let displayText {
            messages.append(ChatMessage(
                id: UUID(), role: .user, text: displayText,
                result: nil, progressText: nil, errorText: nil
            ))
        }

        let progress = "正在理解…"
        let historyUser = nextSource?.context ?? question ?? ""
        let spec = RequestSpec(
            sequence: sequence,
            question: question,
            nextSource: nextSource,
            historyUser: historyUser,
            progressText: progress
        )
        messages.append(ChatMessage(
            id: requestID, role: .assistant, text: nil,
            result: nil, progressText: progress, errorText: nil
        ))
        startTask(requestID: requestID, spec: spec, history: historySnapshot(before: sequence))
    }

    private func startTask(
        requestID: UUID,
        spec: RequestSpec,
        history: [(String, String)]
    ) {
        activeRequestCount += 1
        requestTasks[requestID] = Task { [weak self] in
            guard let self else { return }
            await send(requestID: requestID, spec: spec, history: history)
        }
    }

    private func send(
        requestID: UUID,
        spec: RequestSpec,
        history: [(String, String)]
    ) async {
        do {
            let result = try await LireClient.answer(
                source: source,
                question: spec.question,
                history: history,
                fragments: sourceFragments,
                bookContext: bookContext,
                nextSource: spec.nextSource,
                progress: { [weak self] stage in
                    self?.updateStage(stage, requestID: requestID)
                }
            )
            guard !Task.isCancelled else {
                finish(requestID)
                return
            }

            completedTurns[requestID] = CompletedTurn(
                sequence: spec.sequence,
                user: spec.historyUser,
                assistant: result.answer.conversationText
            )
            updateMessage(requestID) {
                $0.result = result
                $0.progressText = nil
                $0.errorText = nil
            }
            if result.searched, !visible {
                hasUnreadSearchResult = true
            }
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else {
                finish(requestID)
                return
            }
            failedRequests[requestID] = spec
            updateMessage(requestID) {
                $0.progressText = nil
                $0.errorText = error.localizedDescription
            }
        }

        finish(requestID)
    }

    private func historySnapshot(before sequence: Int) -> [(String, String)] {
        completedTurns.values
            .filter { $0.sequence < sequence }
            .sorted { $0.sequence < $1.sequence }
            .map { ($0.user, $0.assistant) }
    }

    private func updateMessage(_ id: UUID, change: (inout ChatMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[index])
    }

    private func updateStage(_ stage: LireRequestStage, requestID: UUID) {
        let text: String
        switch stage {
        case .decidingSearch:
            text = "正在理解…"
        case .searchingWeb:
            activeSearchRequestIDs.insert(requestID)
            activeSearchRequestCount = activeSearchRequestIDs.count
            text = "正在搜索网络…"
        case .answering(let searched):
            text = searched ? "正在整理搜索结果…" : "正在理解…"
        }
        updateMessage(requestID) { $0.progressText = text }
    }

    private func finish(_ requestID: UUID) {
        if requestTasks.removeValue(forKey: requestID) != nil {
            activeRequestCount = max(0, activeRequestCount - 1)
        }
        if activeSearchRequestIDs.remove(requestID) != nil {
            activeSearchRequestCount = activeSearchRequestIDs.count
        }
    }
}

struct AIReadingSheet: View {
    @ObservedObject var conversation: AIReadingConversation

    @Environment(\.dismiss) private var dismiss
    @FocusState private var typing: Bool
    @State private var detent: PresentationDetent = .large

    private let paper = Color(red: 0.985, green: 0.973, blue: 0.941)

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("AI 查找")
                    .font(.headline)

                Spacer()

                Button {
                    typing = false
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.black)
                .background(.ultraThinMaterial, in: Circle())
                .accessibilityLabel("关闭")
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    CollapsibleSourceText(
                        text: conversation.source,
                        expanded: $conversation.sourceExpanded,
                        expandSheet: { detent = .large }
                    )

                    Divider()

                    ForEach(conversation.messages) { message in
                        if message.role == .user, let text = message.text {
                            HStack {
                                Spacer(minLength: 42)
                                Text(text)
                                    .font(.system(size: 17))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(Color.black.opacity(0.07), in: RoundedRectangle(cornerRadius: 17))
                            }
                        } else if let result = message.result {
                            answerView(result)
                            Divider()
                        } else if let progress = message.progressText {
                            ProgressView(progress)
                        } else if let error = message.errorText {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(error)
                                    .font(.subheadline)
                                    .foregroundStyle(.red)
                                Button("重试") { conversation.retry(message.id) }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 14)
            }
            .scrollDismissesKeyboard(.interactively)
            .overlay(alignment: .top) {
                LinearGradient(
                    colors: [paper, paper.opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 18)
                .allowsHitTesting(false)
            }

            HStack(spacing: 8) {
                TextField("继续提问…", text: $conversation.question, axis: .vertical)
                    .lineLimit(1...2)
                    .font(.system(size: 17))
                    .focused($typing)
                    .submitLabel(.send)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        Color.black.opacity(0.045),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                    .onSubmit {
                        typing = false
                        conversation.submitQuestion()
                    }

                Button {
                    typing = false
                    conversation.submitQuestion()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(.black, in: Circle())
                .disabled(
                    conversation.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || conversation.loading
                        || !conversation.hasCompletedAnswer
                )
                .accessibilityLabel("发送")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
        }
        .background(paper)
        .preferredColorScheme(.light)
        .presentationBackground(paper)
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .onAppear {
            conversation.markVisible()
            conversation.startIfNeeded()
        }
        .onDisappear { conversation.markHidden() }
    }

    @ViewBuilder
    private func answerView(_ result: LireResult) -> some View {
        let answer = result.answer

        VStack(alignment: .leading, spacing: 8) {
            if answer.type == "vocabulary", let core = answer.core {
                Text(core.display ?? conversation.source)
                    .font(.title2.bold())

                Text([core.lemma, core.partOfSpeech]
                    .compactMap { $0 }
                    .joined(separator: " · "))
                .foregroundStyle(.secondary)

                if let morphology = core.morphology, !morphology.isEmpty {
                    Text(morphology)
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }

                ForEach(Array(core.displayedSenses.enumerated()), id: \.offset) { index, sense in
                    VStack(alignment: .leading, spacing: 7) {
                        Text((core.displayedSenses.count > 1 ? "\(index + 1). " : "") +
                             (sense.translationsZh ?? []).joined(separator: "；"))
                            .font(.headline)
                            .padding(.top, index == 0 ? 3 : 9)

                        if let definition = sense.definitionFr, !definition.isEmpty {
                            vocabularyLabel("法语解释：")
                            Text(definition)
                                .padding(.leading, 15)
                        }
                        if let example = sense.exampleFr, !example.isEmpty {
                            vocabularyLabel("例句：")
                            Text(example)
                                .padding(.leading, 15)
                            if let translation = sense.exampleZh, !translation.isEmpty {
                                Text(translation)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 15)
                            }
                        }
                    }
                }

                let supplement = ([answer.contextNote].compactMap { $0 } +
                    (answer.extras ?? []).map { "\($0.title)：\($0.content)" })
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                if !supplement.isEmpty {
                    vocabularyLabel("补充：")
                    ForEach(supplement, id: \.self) { text in
                        Text(text)
                            .padding(.leading, 15)
                    }
                }
            } else {
                if answer.type == "chat" {
                    MarkdownAnswerText(answer.content ?? answer.translation ?? "")
                } else {
                    Text(answer.translation ?? answer.content ?? "")
                }

                if let note = answer.note {
                    Text(note)
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
            }

            if result.searched {
                SearchReferencesView(references: result.references)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.system(size: 17))
        .textSelection(.enabled)
    }

    private func vocabularyLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.primary.opacity(0.78))
            .padding(.top, 4)
    }
}

private struct SearchReferencesView: View {
    let references: [LireReference]

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Text("已查询网络")
                    if !references.isEmpty {
                        Text(expanded ? "收起参考内容" : "展开参考内容")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(references.isEmpty)

            if expanded {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(references.enumerated()), id: \.element.id) { index, reference in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text("\(index + 1).")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Link(reference.title, destination: reference.url)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .font(.system(size: 15))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.top, 3)
    }
}

private struct CollapsibleSourceText: View {
    let text: String
    @Binding var expanded: Bool
    let expandSheet: () -> Void

    @State private var collapsedHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    private var needsExpansion: Bool {
        fullHeight > collapsedHeight + 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(text)
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : 4)
                .textSelection(.enabled)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: CollapsedSourceHeightKey.self,
                            value: expanded ? collapsedHeight : proxy.size.height
                        )
                    }
                }
                .background {
                    Text(text)
                        .font(.system(size: 16))
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: FullSourceHeightKey.self,
                                    value: proxy.size.height
                                )
                            }
                        }
                }

            if needsExpansion {
                Button(expanded ? "收起原文" : "展开原文") {
                    expanded.toggle()
                    if expanded { expandSheet() }
                }
                .font(.caption)
            }
        }
        .onPreferenceChange(CollapsedSourceHeightKey.self) { value in
            if value > 0 { collapsedHeight = value }
        }
        .onPreferenceChange(FullSourceHeightKey.self) { value in
            if value > 0 { fullHeight = value }
        }
    }
}

private struct CollapsedSourceHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct FullSourceHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct MarkdownAnswerText: View {
    private enum Block {
        case heading(level: Int, text: String)
        case bullet(String)
        case numbered(marker: String, text: String)
        case quote(String)
        case paragraph(String)
        case rule
    }

    private let blocks: [Block]

    init(_ source: String) {
        blocks = Self.parse(source)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(headingFont(level))
                .padding(.top, level <= 2 ? 7 : 3)

        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•")
                Text(Self.inline(text))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 5)

        case .numbered(let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker)
                    .monospacedDigit()
                Text(Self.inline(text))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 5)

        case .quote(let text):
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.primary.opacity(0.22))
                    .frame(width: 3)
                Text(Self.inline(text))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .paragraph(let text):
            Text(Self.inline(text))
                .frame(maxWidth: .infinity, alignment: .leading)

        case .rule:
            Divider()
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title2.bold()
        case 2: .title3.weight(.semibold)
        case 3: .headline
        default: .subheadline.weight(.semibold)
        }
    }

    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    private static func parse(_ source: String) -> [Block] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        var result: [Block] = []
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            result.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph.removeAll(keepingCapacity: true)
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            if ["---", "***", "___"].contains(trimmed) {
                flushParagraph()
                result.append(.rule)
                continue
            }

            let headingLevel = min(6, trimmed.prefix { $0 == "#" }.count)
            if headingLevel > 0 {
                let contentStart = trimmed.index(trimmed.startIndex, offsetBy: headingLevel)
                let content = trimmed[contentStart...]
                    .trimmingCharacters(in: .whitespaces)
                if !content.isEmpty {
                    flushParagraph()
                    result.append(.heading(level: headingLevel, text: content))
                    continue
                }
            }

            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flushParagraph()
                result.append(.bullet(String(trimmed.dropFirst(2))))
                continue
            }

            if let dot = trimmed.firstIndex(of: "."), dot != trimmed.startIndex {
                let markerText = trimmed[..<dot]
                let afterDot = trimmed.index(after: dot)
                if markerText.allSatisfy(\.isNumber), afterDot < trimmed.endIndex,
                   trimmed[afterDot].isWhitespace {
                    flushParagraph()
                    let textStart = trimmed.index(after: afterDot)
                    result.append(.numbered(
                        marker: String(markerText) + ".",
                        text: String(trimmed[textStart...])
                    ))
                    continue
                }
            }

            if trimmed.hasPrefix("> ") {
                flushParagraph()
                result.append(.quote(String(trimmed.dropFirst(2))))
                continue
            }

            paragraph.append(line)
        }
        flushParagraph()
        return result
    }
}
