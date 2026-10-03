import SwiftUI

private enum NotePaper {
    static let background = Color(red: 0.96, green: 0.94, blue: 0.88)
    static let card = Color(red: 1, green: 0.99, blue: 0.95)
    static let ink = Color(red: 0.24, green: 0.21, blue: 0.17)
    static let accent = Color(red: 0.55, green: 0.38, blue: 0.19)
}

struct VocabularyNotesView: View {
    @ObservedObject private var store = VocabularyNotesStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var selectedDays: Set<Date> = []
    @State private var previewNotes: [VocabularyNote]?
    var bookID: UUID? = nil
    var bookTitle: String? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let error = store.storageError {
                        Text(error).font(.footnote).foregroundStyle(.red)
                        Button("重试保存") { store.retrySave() }
                    }
                    if let bookID {
                        Text(bookTitle ?? "本书").font(.subheadline).foregroundStyle(NotePaper.accent)
                        NoteCardsList(notes: store.today(bookID: bookID))
                    } else if store.notes.isEmpty {
                        NotesEmptyState()
                    } else {
                        Text("阅读中遇见的词，按日留在这里。")
                            .font(.subheadline).foregroundStyle(NotePaper.ink.opacity(0.65))
                        ForEach(store.days(), id: \.self) { day in
                            Group {
                                if editing {
                                    Button {
                                        if !selectedDays.insert(day).inserted { selectedDays.remove(day) }
                                    } label: { dayRow(day) }
                                } else {
                                    NavigationLink { NotesDayView(day: day, store: store) } label: { dayRow(day) }
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                }.padding(22)
            }
            .safeAreaInset(edge: .bottom) {
                if editing && !selectedDays.isEmpty {
                    Button { prepareImport() } label: {
                        Text("导入成为便签（\(selectedDays.count) 天）")
                            .font(.headline).frame(maxWidth: .infinity).padding(16)
                    }
                    .tint(NotePaper.accent).buttonStyle(.borderedProminent)
                    .padding().background(NotePaper.background)
                }
            }
            .sheet(isPresented: Binding(get: { previewNotes != nil }, set: { if !$0 { previewNotes = nil } })) {
                if let previewNotes { NotesImportPreview(notes: previewNotes) }
            }
            .background(NotePaper.background.ignoresSafeArea())
            .foregroundStyle(NotePaper.ink)
            .navigationTitle(bookID == nil ? "查词便签" : "本书今日查词")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if bookID == nil && !store.notes.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(editing ? "取消" : "选择") { editing.toggle(); selectedDays.removeAll() }.tint(NotePaper.accent)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }.tint(NotePaper.accent)
                }
            }
        }.preferredColorScheme(.light)
    }
    private func dayRow(_ day: Date) -> some View {
        HStack(spacing: 16) {
            Image(systemName: editing ? (selectedDays.contains(day) ? "checkmark.circle.fill" : "circle") : "note.text")
                .font(.title2).foregroundStyle(NotePaper.accent)
            VStack(alignment: .leading, spacing: 5) {
                Text(day, format: .dateTime.year().month().day()).font(.system(.headline, design: .serif))
                Text("\(store.on(day).count) 张便签").font(.caption).foregroundStyle(NotePaper.ink.opacity(0.6))
            }
            Spacer()
            if !editing { Image(systemName: "chevron.right").font(.caption.weight(.semibold)) }
        }.padding(20).background(NotePaper.card, in: RoundedRectangle(cornerRadius: 16))
            .shadow(color: NotePaper.ink.opacity(0.08), radius: 8, y: 4)
    }
    private func prepareImport() {
        previewNotes = store.selectedNotes(days: selectedDays)
    }

}

private struct NotesImportPreview: View {
    @Environment(\.dismiss) private var dismiss
    let notes: [VocabularyNote]
    let removedCount: Int
    @State private var selectedIDs: Set<UUID>

    init(notes: [VocabularyNote]) {
        let unique = VocabularyNote.unique(notes)
        self.notes = unique
        removedCount = notes.count - unique.count
        _selectedIDs = State(initialValue: Set(unique.map(\.id)))
    }
    private var days: [Date] {
        Set(notes.map { Calendar.current.startOfDay(for: $0.createdAt) }).sorted(by: >)
    }
    private var selected: [VocabularyNote] { notes.filter { selectedIDs.contains($0.id) } }
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    Text("已默认选择全部便签，点击卡片可去掉不需要的词义。")
                        .font(.subheadline).foregroundStyle(NotePaper.ink.opacity(0.65))
                    if removedCount > 0 {
                        Text("已合并 \(removedCount) 张重复便签。")
                            .font(.footnote).foregroundStyle(NotePaper.accent)
                    }
                    ForEach(days, id: \.self) { day in
                        Text(day, format: .dateTime.year().month().day())
                            .font(.system(.headline, design: .serif)).padding(.top, 8)
                        ForEach(notes.filter { Calendar.current.isDate($0.createdAt, inSameDayAs: day) }) { note in
                            Button {
                                if !selectedIDs.insert(note.id).inserted { selectedIDs.remove(note.id) }
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    Label(selectedIDs.contains(note.id) ? "已选择" : "未选择",
                                          systemImage: selectedIDs.contains(note.id) ? "checkmark.circle.fill" : "circle")
                                        .font(.subheadline).foregroundStyle(NotePaper.accent)
                                    NoteCardsList(notes: [note]).allowsHitTesting(false)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)

                        }
                    }
                }.padding(22)
            }
            .background(NotePaper.background.ignoresSafeArea())
            .foregroundStyle(NotePaper.ink)
            .navigationTitle("预览").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(selectedIDs.count == notes.count ? "取消全选" : "全选") {
                        selectedIDs = selectedIDs.count == notes.count ? [] : Set(notes.map(\.id))
                    }.tint(NotePaper.accent)
                }
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() }.tint(NotePaper.accent) }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if let payload = try? VocabularyNote.importPayload(selected), !selected.isEmpty {
                        ShareLink(item: payload) {
                            Text("导出已选便签（\(selected.count) 张）")
                                .font(.headline).frame(maxWidth: .infinity).padding(14)
                        }.buttonStyle(.borderedProminent).tint(NotePaper.accent)
                    } else {
                        Text("请选择需要导出的便签").font(.subheadline)
                    }
                    Text("发送接口尚未配置，目前可分享便签数据。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding().background(NotePaper.background)
            }
        }.preferredColorScheme(.light)
    }
}

private struct NotesDayView: View {
    let day: Date
    @ObservedObject var store: VocabularyNotesStore
    var body: some View {
        ScrollView { NoteCardsList(notes: store.on(day)).padding(22) }
            .background(NotePaper.background.ignoresSafeArea())
            .foregroundStyle(NotePaper.ink)
            .navigationTitle(day.formatted(.dateTime.year().month().day()))
            .navigationBarTitleDisplayMode(.inline)
    }
}

private struct NoteCardsList: View {
    let notes: [VocabularyNote]
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            if notes.isEmpty { NotesEmptyState() }
            ForEach(notes) { note in
                VStack(alignment: .leading, spacing: 12) {
                    Text("正面").font(.caption.weight(.medium)).foregroundStyle(NotePaper.accent)
                    Text(note.front).font(ReadingTypography.swiftUIFont(size: 25)).textSelection(.enabled)
                    Rectangle().fill(NotePaper.accent.opacity(0.18)).frame(height: 1)
                    Text("背面").font(.caption.weight(.medium)).foregroundStyle(NotePaper.accent)
                    Text(note.back).font(ReadingTypography.swiftUIFont(size: 19)).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(22)
                .background(NotePaper.card, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(NotePaper.accent.opacity(0.13)))
                .shadow(color: NotePaper.ink.opacity(0.09), radius: 9, x: 0, y: 5)
            }
        }
    }
}

private struct NotesEmptyState: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "note.text").font(.system(size: 36)).foregroundStyle(NotePaper.accent.opacity(0.7))
            Text("还没有查词便签").font(.system(.headline, design: .serif))
            Text("词汇卡出现后，每个词义会自动留下正反面便签。")
                .font(.subheadline).multilineTextAlignment(.center).foregroundStyle(NotePaper.ink.opacity(0.6))
        }.frame(maxWidth: .infinity).padding(.vertical, 70)
    }
}
