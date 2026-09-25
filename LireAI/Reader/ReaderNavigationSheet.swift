import ReadiumShared
import SwiftUI

struct ReaderChapterEntry: Identifiable {
    let id: String
    let title: String
    let depth: Int
    let locator: Locator
    var page: Int?
}

enum ReaderNavigationTarget {
    case chapter(Locator)
    case page(Int)
}

struct ReaderSettingsPopover: View {
    @Binding var fontSize: Double
    @Binding var themeRaw: String
    let foreground: Color
    let hasPendingSelection: Bool
    let cancelPendingSelection: () -> Void
    let openNavigation: () -> Void

    @State private var revealedItems = 0
    @State private var closing = false

    var body: some View {
        VStack(spacing: 10) {
            if hasPendingSelection {
                Button(action: cancelPendingSelection) {
                    HStack(spacing: 8) {
                        Image(systemName: "xmark.circle")
                        Text("取消暂存")
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(foreground.opacity(0.78))
                    .padding(.horizontal, 14)
                    .frame(height: 42)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .readerMenuBubble(visible: revealedItems >= 1)
            }

            HStack(spacing: 12) {
                Text("A").font(.system(size: 13, weight: .medium))
                Slider(value: $fontSize, in: 0.9...1.5, step: 0.02)
                Text("A").font(.system(size: 22, weight: .medium))
            }
            .padding(.horizontal, 14)
            .frame(height: 54)
            .readerMenuBubble(visible: revealedItems >= 1)

            Picker("阅读主题", selection: $themeRaw) {
                Label("日间", systemImage: "sun.max.fill").tag(ReaderThemeMode.warm.rawValue)
                Label("夜间", systemImage: "moon.fill").tag(ReaderThemeMode.night.rawValue)
            }
            .pickerStyle(.segmented)
            .padding(10)
            .readerMenuBubble(visible: revealedItems >= 2)

            Button {
                closeThenOpenNavigation()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "list.bullet.indent")
                        .font(.system(size: 15, weight: .semibold))
                    Text("章节与页码")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(foreground.opacity(0.42))
                }
                .foregroundStyle(foreground.opacity(0.82))
                .padding(.horizontal, 14)
                .frame(height: 46)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .readerMenuBubble(visible: revealedItems >= 3)
        }
        .padding(12)
        .frame(width: 300)
        .presentationCompactAdaptation(.popover)
        .task {
            for item in 1...3 {
                guard !Task.isCancelled else { return }
                withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                    revealedItems = item
                }
                try? await Task.sleep(for: .milliseconds(65))
            }
        }
    }

    private func closeThenOpenNavigation() {
        guard !closing else { return }
        closing = true
        Task { @MainActor in
            for item in stride(from: 2, through: 0, by: -1) {
                withAnimation(.easeInOut(duration: 0.10)) { revealedItems = item }
                try? await Task.sleep(for: .milliseconds(45))
            }
            openNavigation()
        }
    }
}

private extension View {
    func readerMenuBubble(visible: Bool) -> some View {
        background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .opacity(visible ? 1 : 0)
            .scaleEffect(visible ? 1 : 0.90, anchor: .trailing)
            .offset(x: visible ? 0 : 10)
    }
}

struct ReaderNavigationSheet: View {
    let chapters: [ReaderChapterEntry]
    let totalPages: Int?
    let currentPage: Int?
    let selectChapter: (Locator) -> Void
    let selectPage: (Int) -> Void
    let close: () -> Void

    @State private var pageText = ""
    @FocusState private var pageFieldFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Group {
                    if chapters.isEmpty {
                        ContentUnavailableView(
                            "没有章节目录",
                            systemImage: "list.bullet.rectangle",
                            description: Text("这本 EPUB 没有提供目录信息。")
                        )
                    } else {
                        List(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                            let active = isActiveChapter(at: index)
                            Button {
                                selectChapter(chapter.locator)
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(chapter.title)
                                        .font(.system(
                                            size: chapter.depth == 0 ? 16 : 15,
                                            weight: chapter.depth == 0 ? .semibold : .regular
                                        ))
                                        .foregroundStyle(active ? Color.accentColor : .primary)
                                        .multilineTextAlignment(.leading)
                                        .padding(.leading, CGFloat(min(chapter.depth, 4)) * 20)
                                    Spacer(minLength: 12)
                                    if let page = chapter.page {
                                        Text(String(page))
                                            .font(.system(size: 13, weight: .regular, design: .rounded).monospacedDigit())
                                            .foregroundStyle(active ? Color.accentColor : .secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .listStyle(.plain)
                    }
                }

                Divider()
                HStack(spacing: 10) {
                    TextField("输入页码", text: $pageText)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.plain)
                        .focused($pageFieldFocused)
                        .submitLabel(.go)
                        .onSubmit(submitPage)
                    Text("/ \(totalPages.map(String.init) ?? "—")")
                        .font(.system(size: 14, design: .rounded).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button(action: submitPage) {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .disabled(validPage == nil)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
            }
            .navigationTitle("章节与页码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("关闭")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }


    private func isActiveChapter(at index: Int) -> Bool {
        guard let currentPage, chapters.indices.contains(index),
              let start = chapters[index].page, start <= currentPage else { return false }

        let nextStart = chapters[(index + 1)...]
            .compactMap(\.page)
            .first(where: { $0 > start })
        return currentPage < (nextStart ?? Int.max)
    }

    private var validPage: Int? {
        guard let page = Int(pageText), let totalPages, (1...totalPages).contains(page) else { return nil }
        return page
    }

    private func submitPage() {
        guard let page = validPage else { return }
        pageFieldFocused = false
        selectPage(page)
    }
}
