import SwiftUI
import Combine

private enum MessageRole { case user, assistant }

private struct ChatMessage: Identifiable {
    let id = UUID()
    let role: MessageRole
    let text: String?
    let result: LireResult?
}

/// One transient lookup conversation. It deliberately lives outside the panel
/// view so collapsing the panel does not destroy context. Starting a new lookup
/// replaces this object and releases the previous messages/history immediately.
@MainActor
final class AIReadingConversation: ObservableObject, Identifiable {
    let id = UUID()
    let source: String
    let sourceFragments: [String]?

    @Published fileprivate var messages: [ChatMessage] = []
    @Published fileprivate var retryQuestion: String?
    @Published var question = ""
    @Published var loading = false
    @Published var error: String?
    @Published var sourceExpanded = false

    private var history: [(String, String)] = []
    private var requestTask: Task<Void, Never>?
    private var started = false

    init(fragments: [String]) {
        let clean = fragments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        sourceFragments = clean.count > 1 ? clean : nil
        source = clean.joined(separator: " ")
    }

    func startIfNeeded() {
        guard !started, !source.isEmpty else { return }
        started = true
        startRequest(nil)
    }

    func submitQuestion() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !loading, !messages.isEmpty else { return }
        question = ""
        messages.append(ChatMessage(role: .user, text: text, result: nil))
        startRequest(text)
    }

    func retry() {
        guard !loading else { return }
        startRequest(retryQuestion)
    }

    func cancelOutstandingRequest() {
        requestTask?.cancel()
        requestTask = nil
        loading = false
    }

    private func startRequest(_ text: String?) {
        requestTask?.cancel()
        requestTask = Task { [weak self] in
            guard let self else { return }
            await send(text)
        }
    }

    private func send(_ text: String?) async {
        guard !loading else { return }

        let clean = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        if messages.isEmpty && clean != nil { return }
        if !messages.isEmpty && (clean?.isEmpty ?? true) { return }

        loading = true
        error = nil
        retryQuestion = clean

        do {
            let result = try await LireClient.answer(
                source: source,
                question: clean,
                history: history,
                fragments: sourceFragments
            )
            guard !Task.isCancelled else {
                loading = false
                return
            }

            if let clean {
                history.append((clean, result.answer.plainText))
            } else {
                history.append(("", result.answer.plainText))
            }
            messages.append(ChatMessage(role: .assistant, text: nil, result: result))
            retryQuestion = nil
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else {
                loading = false
                return
            }
            self.error = error.localizedDescription
        }

        loading = false
        requestTask = nil
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
                    Text(conversation.source)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(conversation.sourceExpanded ? nil : 4)
                        .textSelection(.enabled)

                    if conversation.source.count > 140 {
                        Button(conversation.sourceExpanded ? "收起原文" : "展开原文") {
                            conversation.sourceExpanded.toggle()
                            detent = .large
                        }
                        .font(.caption)
                    }

                    Divider()

                    ForEach(conversation.messages) { message in
                        if message.role == .user, let text = message.text {
                            HStack {
                                Spacer(minLength: 42)
                                Text(text)
                                    .font(.subheadline)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(Color.black.opacity(0.07), in: RoundedRectangle(cornerRadius: 17))
                            }
                        } else if let result = message.result {
                            answerView(result)
                            Divider()
                        }
                    }

                    if conversation.loading {
                        ProgressView("正在理解…")
                    }

                    if let error = conversation.error {
                        Text(error)
                            .font(.subheadline)
                            .foregroundStyle(.red)

                        Button("重试") {
                            conversation.retry()
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
                        || conversation.messages.isEmpty
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
        .onAppear { conversation.startIfNeeded() }
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
                        .font(.subheadline)
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
                    (answer.extras ?? []).prefix(2).map { "\($0.title)：\($0.content)" })
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                if !supplement.isEmpty {
                    vocabularyLabel("补充：")
                    ForEach(supplement, id: \.self) { text in
                        Text(text)
                            .padding(.leading, 15)
                    }
                }
            } else {
                Text(answer.translation ?? answer.content ?? "")

                if let note = answer.note {
                    Text(note)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if result.searched {
                Text("已查询网络")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            ForEach(result.references) { ref in
                Link(ref.title, destination: ref.url)
                    .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.system(size: 15))
        .textSelection(.enabled)
    }

    private func vocabularyLabel(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary.opacity(0.78))
            .padding(.top, 4)
    }
}
