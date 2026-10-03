import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ContentView: View {
    @StateObject private var library = LibraryStore()
    @State private var importing = false
    @State private var importingBook = false
    @State private var importProgress = 0.0
    @State private var importingTitle = ""
    @State private var importingCoverURL: URL?
    @State private var showingSettings = false
    @State private var showingVocabularyNotes = false
    @State private var reading: BookRecord?
    @State private var bookPendingDeletion: BookRecord?
    @State private var error: String?

    private let epubType = UTType(filenameExtension: "epub") ?? .data
    private let bronze = Color(red: 0.72, green: 0.52, blue: 0.26)
    private let primaryText = Color.white.opacity(0.94)
    private let secondaryText = Color.white.opacity(0.58)

    var body: some View {
        ZStack {
            HomeBackground()
            NavigationStack { homeContent }
            if importingBook { importOverlay }
        }
        .preferredColorScheme(.dark)
    }

    private var homeContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 32) {
                continueReadingSection
                librarySection
            }
            .padding(.horizontal, 26)
            .padding(.top, 18)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(Color.clear)
        .navigationTitle(" LireAI")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar { navigationToolbar }
        .sheet(isPresented: $showingVocabularyNotes) { VocabularyNotesView() }
        .sheet(isPresented: $showingSettings) { SettingsView().preferredColorScheme(.light) }
        .fullScreenCover(item: $reading) { book in ReaderView(book: book, library: library) { reading = nil } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [epubType], onCompletion: handleImportResult)
        .alert("导入失败", isPresented: errorAlertBinding) { Button("好") { error = nil } } message: { Text(error ?? "") }
        .alert("删除书籍？", isPresented: deleteAlertBinding) { deleteAlertButtons } message: { deleteAlertMessage }
    }

    @ViewBuilder private var continueReadingSection: some View {
        if let current = library.continueBook {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("继续阅读")
                ContinueReadingCard(book: current, coverURL: library.coverURL(for: current), primaryText: primaryText, secondaryText: secondaryText, bronze: bronze) { open(current) }
            }
        }
    }

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                sectionTitle("我的书籍")
                Spacer()
                importButton
            }
            if library.books.isEmpty { emptyLibraryView } else { libraryPager }
        }
    }

    private var importButton: some View {
        Button { importing = true } label: {
            Label("导入", systemImage: "plus")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(primaryText)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.09), in: Capsule())
                .overlay { Capsule().stroke(Color.white.opacity(0.08), lineWidth: 0.5) }
        }
        .buttonStyle(.plain)
        .disabled(importingBook)
    }

    private var emptyLibraryView: some View {
        VStack(spacing: 8) {
            Image(systemName: "books.vertical").font(.title2).foregroundStyle(bronze.opacity(0.9))
            Text("暂无书籍").font(.headline).foregroundStyle(primaryText)
            Text("导入一个 EPUB 开始阅读").font(.subheadline).foregroundStyle(secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 38)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18))
    }

    private var libraryPager: some View {
        TabView {
            ForEach(0..<pageCount, id: \.self) { page in libraryPage(page) }
        }
        .tabViewStyle(.page(indexDisplayMode: .automatic))
        .frame(height: 272)
    }

    private var pageCount: Int { (library.books.count + 2) / 3 }

    private func libraryPage(_ page: Int) -> some View {
        let books = pageBooks(page)
        return VStack(spacing: 0) {
            ForEach(books) { book in
                BookRow(book: book, coverURL: library.coverURL(for: book), primaryText: primaryText, secondaryText: secondaryText, isLast: book.id == books.last?.id, onOpen: { open(book) }, onDelete: { bookPendingDeletion = book })
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))
    }

    @ToolbarContentBuilder private var navigationToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { showingVocabularyNotes = true } label: {
                Image(systemName: "note.text")
                    .font(.body.weight(.medium)).foregroundStyle(primaryText)
            }.accessibilityLabel("查词便签")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { showingSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.body.weight(.medium))
                    .foregroundStyle(primaryText)
            }
            .accessibilityLabel("设置")
        }
    }

    private var importOverlay: some View {
        ZStack {
            Color.black.opacity(0.34).ignoresSafeArea().contentShape(Rectangle())
            HStack(spacing: 18) {
                importCover
                VStack(alignment: .leading, spacing: 10) {
                    Text("导入中").font(.subheadline.weight(.semibold))
                    Text(importingTitle.isEmpty ? "EPUB" : importingTitle).font(.body.weight(.medium)).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                    ProgressView(value: importProgress, total: 1).progressViewStyle(.linear).tint(bronze)
                    Text("\(Int(min(max(importProgress, 0), 1) * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
                }
                .frame(width: 205)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(radius: 18, y: 8)
        }
        .zIndex(20)
    }

    @ViewBuilder private var importCover: some View {
        if let importingCoverURL {
            BookCover(url: importingCoverURL).frame(width: 68, height: 96)
        } else {
            ZStack {
                Color(red: 0.32, green: 0.29, blue: 0.24)
                Image(systemName: "book.closed").font(.title2).foregroundStyle(.white)
            }
            .frame(width: 68, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }

    private var errorAlertBinding: Binding<Bool> { Binding(get: { error != nil }, set: { if !$0 { error = nil } }) }
    private var deleteAlertBinding: Binding<Bool> { Binding(get: { bookPendingDeletion != nil }, set: { if !$0 { bookPendingDeletion = nil } }) }

    @ViewBuilder private var deleteAlertButtons: some View {
        Button("取消", role: .cancel) { bookPendingDeletion = nil }
        Button("删除", role: .destructive) { confirmDeletion() }
    }

    @ViewBuilder private var deleteAlertMessage: some View {
        if let book = bookPendingDeletion { Text("《\(book.title)》以及阅读进度、分页数据和本地缓存都会被删除。此操作无法撤销。") }
    }

    private func sectionTitle(_ title: String) -> some View { Text(title).font(.system(size: 20, weight: .semibold, design: .serif)).foregroundStyle(Color(red: 0.86, green: 0.74, blue: 0.56)) }
    private func pageBooks(_ page: Int) -> [BookRecord] { Array(library.books.dropFirst(page * 3).prefix(3)) }
    private func open(_ book: BookRecord) { library.select(book); reading = book }

    private func confirmDeletion() {
        guard let book = bookPendingDeletion else { return }
        library.delete(book)
        if reading?.id == book.id { reading = nil }
        bookPendingDeletion = nil
    }

    private func handleImportResult(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url): startImport(url)
        case .failure(let error): self.error = error.localizedDescription
        }
    }

    private func startImport(_ url: URL) {
        importingBook = true
        importProgress = 0
        importingTitle = url.deletingPathExtension().lastPathComponent
        importingCoverURL = nil
        Task {
            do {
                let book = try await library.import(from: url, paginationViewport: currentReaderViewport, progress: { importProgress = $0 }, prepared: { preparedBook in importingTitle = preparedBook.title; let cover = library.coverURL(for: preparedBook); importingCoverURL = FileManager.default.fileExists(atPath: cover.path) ? cover : nil })
                open(book)
            } catch {
                self.error = error.localizedDescription
            }
            importingBook = false
            importProgress = 0
            importingTitle = ""
            importingCoverURL = nil
        }
    }

    private var currentReaderViewport: CGSize {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes where scene.activationState == .foregroundActive || scene.activationState == .foregroundInactive {
            if let size = scene.windows.first(where: \.isKeyWindow)?.bounds.size, size.width > 0, size.height > 0 { return size }
        }
        return UIScreen.main.bounds.size
    }
}

private struct ContinueReadingCard: View {
    let book: BookRecord
    let coverURL: URL
    let primaryText: Color
    let secondaryText: Color
    let bronze: Color
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 18) {
                BookCover(url: coverURL).frame(width: 108, height: 156).shadow(color: .black.opacity(0.34), radius: 10, y: 5)
                VStack(alignment: .leading, spacing: 9) {
                    Text(book.title).font(.title3.weight(.semibold)).foregroundStyle(primaryText).multilineTextAlignment(.leading)
                    if !book.author.isEmpty { Text(book.author).font(.subheadline).foregroundStyle(secondaryText) }
                    Spacer(minLength: 10)
                    HStack(spacing: 6) {
                        Text("\(Int(book.progression * 100))% · 继续阅读")
                        Image(systemName: "arrow.right").font(.caption.weight(.semibold))
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.white.opacity(0.82))
                }
                Spacer(minLength: 0)
            }
            .padding(19)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [Color.white.opacity(0.15), Color.white.opacity(0.095)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(bronze.opacity(0.18), lineWidth: 0.7) }
        }
        .buttonStyle(.plain)
    }
}

private struct BookRow: View {
    let book: BookRecord
    let coverURL: URL
    let primaryText: Color
    let secondaryText: Color
    let isLast: Bool
    let onOpen: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onOpen) {
                    HStack(spacing: 14) {
                        BookCover(url: coverURL).frame(width: 52, height: 72)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(book.title).font(.body.weight(.medium)).foregroundStyle(primaryText).lineLimit(2)
                            if !book.author.isEmpty { Text(book.author).font(.caption).foregroundStyle(secondaryText).lineLimit(1) }
                            Text("\(Int(book.progression * 100))%").font(.caption.monospacedDigit()).foregroundStyle(secondaryText)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Menu { Button(role: .destructive, action: onDelete) { Label("删除", systemImage: "trash") } } label: { Image(systemName: "ellipsis").font(.body.weight(.semibold)).foregroundStyle(Color.white.opacity(0.62)).frame(width: 38, height: 44).contentShape(Rectangle()) }
            }
            .frame(height: 83)
            if !isLast { Divider().overlay(Color.white.opacity(0.09)) }
        }
    }
}

private struct HomeBackground: View {
    var body: some View {
        ZStack {
            Color.black

            LinearGradient(
                colors: [
                    Color(red: 0.30, green: 0.18, blue: 0.055).opacity(0.78),
                    Color(red: 0.15, green: 0.085, blue: 0.025).opacity(0.52),
                    Color.black.opacity(0.42),
                    Color.black
                ],
                startPoint: .bottomLeading,
                endPoint: UnitPoint(x: 0.78, y: 0.20)
            )

            RadialGradient(
                colors: [
                    Color(red: 0.56, green: 0.34, blue: 0.10).opacity(0.34),
                    Color(red: 0.31, green: 0.17, blue: 0.045).opacity(0.18),
                    .clear
                ],
                center: UnitPoint(x: 0.05, y: 0.88),
                startRadius: 20,
                endRadius: 430
            )

            LinearGradient(
                colors: [
                    Color.black.opacity(0.90),
                    Color.black.opacity(0.32),
                    .clear
                ],
                startPoint: .top,
                endPoint: UnitPoint(x: 0.5, y: 0.46)
            )
        }
        .ignoresSafeArea()
    }
}

private struct BookCover: View {
    let url: URL

    var body: some View {
        Group {
            if let image = UIImage(contentsOfFile: url.path) { Image(uiImage: image).resizable().scaledToFill() }
            else { ZStack { Color(red: 0.32, green: 0.29, blue: 0.24); Image(systemName: "book.closed").foregroundStyle(.white.opacity(0.9)).font(.title2) } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}
