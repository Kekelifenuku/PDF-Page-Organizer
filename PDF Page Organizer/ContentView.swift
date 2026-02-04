import SwiftUI
import PDFKit
import UniformTypeIdentifiers
import Combine
import RevenueCatUI
// MARK: - Models

struct PageItem: Identifiable, Equatable, Hashable {
    let id: UUID
    let sourceId: UUID
    let sourceName: String
    let originalPageIndex: Int
    var displayIndex: Int
    let page: PDFPage
    var thumbnail: UIImage?
    
    static func == (lhs: PageItem, rhs: PageItem) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct PDFDocumentWrapper: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }
    var pdfDocument: PDFDocument?
    
    init(pdfDocument: PDFDocument? = nil) {
        self.pdfDocument = pdfDocument
    }
    
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.pdfDocument = PDFDocument(data: data)
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard let pdfDocument = pdfDocument,
              let data = pdfDocument.dataRepresentation() else {
            throw CocoaError(.fileWriteUnknown)
        }
        return FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - ViewModel

@MainActor
final class PDFMergerViewModel: ObservableObject {
    @Published var allPages: [PageItem] = []
    @Published var selectedPages: Set<UUID> = []
    @Published var showErrorAlert = false
    @Published var errorMessage: String?
    @Published var showSuccessAlert = false
    @Published var successMessage: String?
    @Published var isLoading = false
    
    private var sourceDocuments: [UUID: PDFDocument] = [:]
    private var thumbnailCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 100 // Limit number of cached thumbnails
        cache.totalCostLimit = 50 * 1024 * 1024 // 50MB limit
        return cache
    }()
    private var thumbnailGenerationTasks: [UUID: Task<Void, Never>] = [:]
    
    var documentCount: Int {
        Set(allPages.map { $0.sourceId }).count
    }
    
    var hasPages: Bool {
        !allPages.isEmpty
    }
    
    deinit {
        thumbnailGenerationTasks.values.forEach { $0.cancel() }
        thumbnailGenerationTasks.removeAll()
        thumbnailCache.removeAllObjects()
    }
    
    func handleDocumentPicker(result: Result<[URL], Error>) {
        Task {
            do {
                let urls = try result.get()
                guard !urls.isEmpty else { return }
                
                isLoading = true
                defer { isLoading = false }
                
                try await addPDFDocuments(from: urls)
                
                if !urls.isEmpty {
                    showSuccessMessage("Added \(urls.count) document(s)")
                }
                
            } catch {
                showError(error)
            }
        }
    }
    
    private func addPDFDocuments(from urls: [URL]) async throws {
        var newPages: [PageItem] = []
        
        for url in urls {
            guard url.startAccessingSecurityScopedResource() else {
                continue
            }
            
            defer { url.stopAccessingSecurityScopedResource() }
            
            guard let document = PDFDocument(url: url) else {
                continue
            }
            
            let sourceId = UUID()
            let sourceName = url.deletingPathExtension().lastPathComponent
            sourceDocuments[sourceId] = document
            
            for i in 0..<document.pageCount {
                guard let page = document.page(at: i) else { continue }
                
                let pageItem = PageItem(
                    id: UUID(),
                    sourceId: sourceId,
                    sourceName: sourceName,
                    originalPageIndex: i,
                    displayIndex: allPages.count + newPages.count + 1,
                    page: page,
                    thumbnail: nil
                )
                newPages.append(pageItem)
            }
        }
        
        // Add all pages immediately (show with loading indicators)
        allPages.append(contentsOf: newPages)
        
        // Generate thumbnails in background without waiting
        Task {
            await generateThumbnails(for: newPages)
        }
    }
    
    private func generateThumbnails(for pages: [PageItem]) async {
        // Process in batches for better performance
        let batchSize = 5
        for i in stride(from: 0, to: pages.count, by: batchSize) {
            let endIndex = min(i + batchSize, pages.count)
            let batch = Array(pages[i..<endIndex])
            
            await withTaskGroup(of: Void.self) { group in
                for pageItem in batch {
                    group.addTask {
                        await self.generateThumbnail(for: pageItem)
                    }
                }
            }
        }
    }
    
    private func generateThumbnail(for pageItem: PageItem) async {
        let page = pageItem.page
        let cacheKey = "\(page.hashValue)" as NSString
        
        if let cachedThumbnail = thumbnailCache.object(forKey: cacheKey) {
            await MainActor.run {
                if let index = self.allPages.firstIndex(where: { $0.id == pageItem.id }) {
                    self.allPages[index].thumbnail = cachedThumbnail
                }
            }
            return
        }
        
        thumbnailGenerationTasks[pageItem.id]?.cancel()
        
        let task = Task {
            guard !Task.isCancelled else { return }
            
            let thumbnail = await Task.detached(priority: .userInitiated) { () -> UIImage in
                // Smaller thumbnail size for faster generation
                let thumbnailSize = CGSize(width: 140, height: 180)
                let pageRect = page.bounds(for: .mediaBox)
                
                // Calculate scale to fit
                let scale = min(
                    thumbnailSize.width / pageRect.width,
                    thumbnailSize.height / pageRect.height
                )
                
                let scaledSize = CGSize(
                    width: pageRect.width * scale,
                    height: pageRect.height * scale
                )
                
                // Use lower quality rendering for speed
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1.0 // Reduce scale for faster rendering
                
                let renderer = UIGraphicsImageRenderer(size: scaledSize, format: format)
                return renderer.image { context in
                    UIColor.white.setFill()
                    context.fill(CGRect(origin: .zero, size: scaledSize))
                    
                    let cgContext = context.cgContext
                    cgContext.saveGState()
                    
                    // Set interpolation quality to low for speed
                    cgContext.interpolationQuality = .low
                    
                    // Flip coordinate system for PDF rendering
                    cgContext.translateBy(x: 0, y: scaledSize.height)
                    cgContext.scaleBy(x: 1.0, y: -1.0)
                    
                    // Scale to fit
                    cgContext.scaleBy(x: scale, y: scale)
                    
                    // Translate to account for page origin
                    cgContext.translateBy(x: -pageRect.origin.x, y: -pageRect.origin.y)
                    
                    // Draw PDF page
                    if let pageRef = page.pageRef {
                        cgContext.drawPDFPage(pageRef)
                    }
                    
                    cgContext.restoreGState()
                }
            }.value
            
            guard !Task.isCancelled else { return }
            
            await MainActor.run {
                self.thumbnailCache.setObject(thumbnail, forKey: cacheKey)
                
                if let index = self.allPages.firstIndex(where: { $0.id == pageItem.id }) {
                    self.allPages[index].thumbnail = thumbnail
                }
                
                self.thumbnailGenerationTasks.removeValue(forKey: pageItem.id)
            }
        }
        
        thumbnailGenerationTasks[pageItem.id] = task
        await task.value
    }
    
    func togglePageSelection(_ pageId: UUID) {
        if selectedPages.contains(pageId) {
            selectedPages.remove(pageId)
        } else {
            selectedPages.insert(pageId)
        }
    }
    
    func selectAllPages() {
        selectedPages = Set(allPages.map { $0.id })
    }
    
    func clearSelection() {
        selectedPages.removeAll()
    }
    
    func deleteSelectedPages() {
        guard !selectedPages.isEmpty,
              selectedPages.count < allPages.count else {
            showError(NSError(
                domain: "PDFMerger",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Cannot delete all pages or no pages selected."]
            ))
            return
        }
        
        for pageId in selectedPages {
            thumbnailGenerationTasks[pageId]?.cancel()
            thumbnailGenerationTasks.removeValue(forKey: pageId)
        }
        
        let deletedCount = selectedPages.count
        allPages.removeAll { selectedPages.contains($0.id) }
        updateDisplayIndices()
        clearSelection()
        showSuccessMessage("Successfully deleted \(deletedCount) page(s)!")
    }
    
    func movePage(from: PageItem, to: PageItem) {
        guard let fromIndex = allPages.firstIndex(where: { $0.id == from.id }),
              let toIndex = allPages.firstIndex(where: { $0.id == to.id }) else {
            return
        }
        
        let page = allPages.remove(at: fromIndex)
        allPages.insert(page, at: toIndex)
        updateDisplayIndices()
    }
    
    func removePage(_ pageItem: PageItem) {
        thumbnailGenerationTasks[pageItem.id]?.cancel()
        thumbnailGenerationTasks.removeValue(forKey: pageItem.id)
        
        allPages.removeAll { $0.id == pageItem.id }
        selectedPages.remove(pageItem.id)
        updateDisplayIndices()
    }
    
    func reverseOrder() {
        allPages.reverse()
        updateDisplayIndices()
    }
    
    func clearAll() {
        thumbnailGenerationTasks.values.forEach { $0.cancel() }
        thumbnailGenerationTasks.removeAll()
        
        allPages.removeAll()
        selectedPages.removeAll()
        sourceDocuments.removeAll()
        thumbnailCache.removeAllObjects()
    }
    
    private func updateDisplayIndices() {
        for i in 0..<allPages.count {
            allPages[i].displayIndex = i + 1
        }
    }
    
    func createMergedPDF() -> PDFDocument {
        let mergedDocument = PDFDocument()
        
        for (index, pageItem) in allPages.enumerated() {
            if let pageCopy = pageItem.page.copy() as? PDFPage {
                mergedDocument.insert(pageCopy, at: index)
            }
        }
        
        return mergedDocument
    }
    
    private func showError(_ error: Error) {
        errorMessage = error.localizedDescription
        showErrorAlert = true
    }
    
    func showSuccessMessage(_ message: String) {
        successMessage = message
        showSuccessAlert = true
    }
}

// MARK: - Supporting Views

struct ToolbarButtonStyle: ButtonStyle {
    let color: Color
    var isProminent = false
    var isDisabled = false
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline)
            .fontWeight(.medium)
            .foregroundColor(isDisabled ? .gray.opacity(0.6) : (isProminent ? .white : color))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                Capsule()
                    .fill(isDisabled ? Color.gray.opacity(0.15) : (isProminent ? color : color.opacity(0.12)))
            )
            .overlay(
                Capsule()
                    .stroke(isDisabled ? Color.gray.opacity(0.2) : (isProminent ? color.opacity(0.3) : color.opacity(0.25)), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed && !isDisabled ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
            .opacity(isDisabled ? 0.5 : 1.0)
    }
}

// MARK: - Merger Components

struct MergerInfoHeader: View {
    @ObservedObject var viewModel: PDFMergerViewModel
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Organized Document")
                        .font(.system(.headline, design: .rounded))
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    
                    HStack(spacing: 10) {
                        Label("\(viewModel.allPages.count) pages", systemImage: "doc.text")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Label("\(viewModel.documentCount) document(s)", systemImage: "doc.on.doc")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        if !viewModel.selectedPages.isEmpty {
                            Label("\(viewModel.selectedPages.count) selected", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundColor(.indigo)
                        }
                    }
                }
                
                Spacer(minLength: 8)
                
                HStack(spacing: 10) {
                    if !viewModel.selectedPages.isEmpty {
                        Button {
                            withAnimation(.spring(response: 0.3)) {
                                viewModel.clearSelection()
                            }
                        } label: {
                            Label("Clear", systemImage: "xmark.circle.fill")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(.indigo)
                        }
                        .buttonStyle(.plain)
                    }
                    
                    Button {
                        withAnimation(.spring(response: 0.3)) {
                            viewModel.clearAll()
                        }
                    } label: {
                        Label("Clear All", systemImage: "trash")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.allPages.isEmpty)
                    .opacity(viewModel.allPages.isEmpty ? 0.5 : 1.0)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                Color(.systemBackground)
                    .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
            )
            
            Divider()
        }
    }
}

struct DraggablePageCard: View {
    let pageItem: PageItem
    @ObservedObject var viewModel: PDFMergerViewModel
    @Binding var draggedPage: PageItem?
    @State private var isTargeted = false
    @State private var isHovered = false
    
    var isSelected: Bool {
        viewModel.selectedPages.contains(pageItem.id)
    }
    
    var body: some View {
        HStack(spacing: 14) {
            // Selection indicator
            Button {
                withAnimation(.spring(response: 0.25)) {
                    viewModel.togglePageSelection(pageItem.id)
                }
            } label: {
                ZStack {
                    Circle()
                        .stroke(isSelected ? Color.indigo : Color.gray.opacity(0.35), lineWidth: 2)
                        .frame(width: 22, height: 22)
                    
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 16, height: 16)
                            .background(
                                Circle()
                                    .fill(Color.indigo)
                            )
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            }
            .buttonStyle(.plain)
            
            // Drag handle
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.7))
                .frame(width: 20)
            
            // Thumbnail
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(.secondarySystemBackground))
                    .frame(width: 70, height: 90)
                
                if let thumbnail = pageItem.thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 66, height: 86)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    ProgressView()
                        .scaleEffect(0.6)
                }
            }
            .shadow(color: .black.opacity(0.08), radius: 3, x: 0, y: 2)
            
            // Page info
            VStack(alignment: .leading, spacing: 3) {
                Text("Page \(pageItem.displayIndex)")
                    .font(.system(.body, design: .rounded))
                    .fontWeight(.semibold)
                    .foregroundColor(isSelected ? .indigo : .primary)
                
                Text(pageItem.sourceName)
                    .font(.system(.caption, design: .rounded))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            Spacer(minLength: 0)
            
            // Delete button
            Button {
                withAnimation(.spring(response: 0.3)) {
                    viewModel.removePage(pageItem)
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundColor(.red.opacity(0.8))
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1.0 : 0.6)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.indigo.opacity(0.08) : Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isTargeted ? Color.indigo.opacity(0.5) : (isSelected ? Color.indigo.opacity(0.2) : Color.clear),
                    lineWidth: isTargeted ? 2 : 1
                )
        )
        .shadow(color: .black.opacity(isHovered ? 0.08 : 0.04), radius: 4, x: 0, y: 2)
        .scaleEffect(draggedPage?.id == pageItem.id ? 0.97 : 1.0)
        .opacity(draggedPage?.id == pageItem.id ? 0.7 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isHovered)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isSelected)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .onDrag {
            self.draggedPage = pageItem
            return NSItemProvider(object: pageItem.id.uuidString as NSString)
        }
        .onDrop(of: [.text], delegate: PageDropDelegate(
            pageItem: pageItem,
            draggedPage: $draggedPage,
            viewModel: viewModel,
            isTargeted: $isTargeted
        ))
    }
}

struct PageDropDelegate: DropDelegate {
    let pageItem: PageItem
    @Binding var draggedPage: PageItem?
    let viewModel: PDFMergerViewModel
    @Binding var isTargeted: Bool
    
    func dropEntered(info: DropInfo) {
        guard let draggedPage = draggedPage,
              draggedPage.id != pageItem.id else { return }
        
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            isTargeted = true
            viewModel.movePage(from: draggedPage, to: pageItem)
        }
    }
    
    func dropExited(info: DropInfo) {
        withAnimation(.spring(response: 0.25)) {
            isTargeted = false
        }
    }
    
    func performDrop(info: DropInfo) -> Bool {
        withAnimation(.spring(response: 0.25)) {
            isTargeted = false
            draggedPage = nil
        }
        return true
    }
}

struct MergerActionToolbar: View {
    @ObservedObject var viewModel: PDFMergerViewModel
    @Binding var showDocumentPicker: Bool
    @Binding var showExportSheet: Bool
    @State private var showDeleteConfirmation = false
    @EnvironmentObject var subscriptionManager: SubscriptionManager

    @State private var showPaywall = false


    var body: some View {
        VStack(spacing: 0) {
            Divider()
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // Select all
                    Button {
                        withAnimation(.spring(response: 0.3)) {
                            viewModel.selectAllPages()
                        }
                    } label: {
                        Label("Select All", systemImage: "checkmark.circle")
                    }
                    .disabled(viewModel.selectedPages.count == viewModel.allPages.count)
                    .buttonStyle(ToolbarButtonStyle(
                        color: .blue,
                        isDisabled: viewModel.selectedPages.count == viewModel.allPages.count
                    ))
                    
                    // Clear selection
                    Button {
                        withAnimation(.spring(response: 0.3)) {
                            viewModel.clearSelection()
                        }
                    } label: {
                        Label("Clear", systemImage: "circle")
                    }
                    .disabled(viewModel.selectedPages.isEmpty)
                    .buttonStyle(ToolbarButtonStyle(
                        color: .gray,
                        isDisabled: viewModel.selectedPages.isEmpty
                    ))
                    
                    // Delete selected
                    Button {
                        showDeleteConfirmation = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(
                        viewModel.selectedPages.isEmpty ||
                        viewModel.selectedPages.count == viewModel.allPages.count
                    )
                    .buttonStyle(ToolbarButtonStyle(
                        color: .red,
                        isDisabled: viewModel.selectedPages.isEmpty ||
                                    viewModel.selectedPages.count == viewModel.allPages.count
                    ))
                    
                    // Add more PDFs
                    Button {
                        showDocumentPicker = true
                    } label: {
                        Label("Add PDF", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(ToolbarButtonStyle(color: .purple))
                    
                    // Reverse order
                    Button {
                        withAnimation(.spring(response: 0.35)) {
                            viewModel.reverseOrder()
                        }
                    } label: {
                        Label("Reverse", systemImage: "arrow.up.arrow.down")
                    }
                    .disabled(viewModel.allPages.isEmpty)
                    .buttonStyle(ToolbarButtonStyle(
                        color: .orange,
                        isDisabled: viewModel.allPages.isEmpty
                    ))
                    
                    // Export
                    Button {
                        if subscriptionManager.isSubscribed {
                            showExportSheet = true
                        } else {
                            showPaywall = true
                        }
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }

                    .disabled(viewModel.allPages.isEmpty)
                    .buttonStyle(ToolbarButtonStyle(
                        color: .green,
                        isProminent: true,
                        isDisabled: viewModel.allPages.isEmpty
                    ))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .background(Color(.systemBackground))
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
        }
        .confirmationDialog(
            "Delete Selected Pages",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete \(viewModel.selectedPages.count) Page(s)", role: .destructive) {
                viewModel.deleteSelectedPages()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This action cannot be undone.")
        }
    }
} 

// MARK: - Main View

struct PDFMergerOrganizerView: View {
    @StateObject private var viewModel = PDFMergerViewModel()
    @State private var showDocumentPicker = false
    @State private var showExportSheet = false
    @State private var showInstructions = false
    @State private var draggedPage: PageItem?
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()
                
                VStack(spacing: 0) {
                    if viewModel.hasPages {
                        // Document info header
                        MergerInfoHeader(viewModel: viewModel)
                        
                        // Pages view with drag and drop
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(viewModel.allPages) { pageItem in
                                    DraggablePageCard(
                                        pageItem: pageItem,
                                        viewModel: viewModel,
                                        draggedPage: $draggedPage
                                    )
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 14)
                        }
                        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: viewModel.allPages)
                        
                        // Action toolbar
                        MergerActionToolbar(
                            viewModel: viewModel,
                            showDocumentPicker: $showDocumentPicker,
                            showExportSheet: $showExportSheet
                        )
                    } else {
                        MergerEmptyStateView(
                            showDocumentPicker: $showDocumentPicker,
                            showInstructions: $showInstructions
                        )
                    }
                }
                
                // Loading overlay
                if viewModel.isLoading {
                    Color.black.opacity(0.25)
                        .ignoresSafeArea()
                        .overlay(
                            VStack(spacing: 16) {
                                ProgressView()
                                    .scaleEffect(1.3)
                                    .tint(.indigo)
                                
                                Text("Loading...")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            .padding(28)
                            .background(
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(Color(.systemBackground))
                                    .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                            )
                        )
                        .transition(.opacity)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if viewModel.hasPages {
                        Button {
                            showDocumentPicker = true
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .symbolRenderingMode(.hierarchical)
                                .foregroundColor(.indigo)
                        }
                        
                        Button {
                            showInstructions.toggle()
                        } label: {
                            Image(systemName: "questionmark.circle")
                                .symbolRenderingMode(.hierarchical)
                                .foregroundColor(.indigo)
                        }
                    }
                }
            }
            .fileImporter(
                isPresented: $showDocumentPicker,
                allowedContentTypes: [.pdf],
                allowsMultipleSelection: true
            ) { result in
                viewModel.handleDocumentPicker(result: result)
            }
            .fileExporter(
                isPresented: $showExportSheet,
                document: PDFDocumentWrapper(pdfDocument: viewModel.createMergedPDF()),
                contentType: .pdf,
                defaultFilename: "merged_document.pdf"
            ) { result in
                if case .success = result {
                    viewModel.showSuccessMessage("PDF exported successfully!")
                }
            }
            .alert("Success", isPresented: $viewModel.showSuccessAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(viewModel.successMessage ?? "Operation completed successfully")
            }
            .alert("Error", isPresented: $viewModel.showErrorAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(viewModel.errorMessage ?? "Unknown error occurred")
            }
            .sheet(isPresented: $showInstructions) {
                MergerInstructionsView()
            }
        }
        .tint(.indigo)
    }
}

// MARK: - Empty State View

struct MergerEmptyStateView: View {
    @Binding var showDocumentPicker: Bool
    @Binding var showInstructions: Bool
    
    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Spacer(minLength: 50)
                
                VStack(spacing: 18) {
                    Image(systemName: "doc.on.doc.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(
                            .linearGradient(
                                colors: [.indigo, .purple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .symbolRenderingMode(.hierarchical)
                    
                    VStack(spacing: 6) {
                        Text("Page Merger & Organizer")
                            .font(.system(.title2, design: .rounded))
                            .fontWeight(.bold)
                            .foregroundColor(.primary)
                        
                        Text("Combine multiple PDFs and arrange pages in any order")
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                }
                
                VStack(spacing: 12) {
                    Button {
                        showDocumentPicker = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle.fill")
                            Text("Import PDF Documents")
                                .fontWeight(.semibold)
                        }
                        .font(.body)
                        .foregroundColor(.white)
                        .frame(maxWidth: 300)
                        .padding(.vertical, 15)
                        .background(
                            Capsule()
                                .fill(
                                    .linearGradient(
                                        colors: [.indigo, .purple],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .shadow(color: .indigo.opacity(0.3), radius: 10, x: 0, y: 5)
                        )
                    }
                    
                    Button {
                        showInstructions = true
                    } label: {
                        Text("How to use")
                            .font(.subheadline)
                            .foregroundColor(.indigo)
                    }
                }
                
                Spacer(minLength: 30)
                
                VStack(alignment: .leading, spacing: 14) {
                    FeatureRow(
                        icon: "hand.tap.fill",
                        iconColor: .indigo,
                        title: "Select Pages",
                        description: "Tap to select pages for bulk operations"
                    )
                    
                    FeatureRow(
                        icon: "arrow.up.arrow.down.circle.fill",
                        iconColor: .blue,
                        title: "Drag & Drop",
                        description: "Drag pages to reorder them visually"
                    )
                    
                    FeatureRow(
                        icon: "plus.circle.fill",
                        iconColor: .green,
                        title: "Multiple PDFs",
                        description: "Combine pages from different documents"
                    )
                    
                    FeatureRow(
                        icon: "square.and.arrow.up.fill",
                        iconColor: .orange,
                        title: "Export",
                        description: "Save your organized PDF with one click"
                    )
                }
                .padding(20)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color(.systemBackground))
                        .shadow(color: .black.opacity(0.06), radius: 10, x: 0, y: 4)
                )
                .padding(.horizontal, 24)
                
                Spacer(minLength: 50)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

struct FeatureRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let description: String
    
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(iconColor)
                .frame(width: 28, height: 28)
                .symbolRenderingMode(.hierarchical)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.subheadline, design: .rounded))
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                
                Text(description)
                    .font(.system(.caption, design: .rounded))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Instructions View

struct MergerInstructionsView: View {
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Header
                    VStack(spacing: 10) {
                        Image(systemName: "doc.on.doc.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(
                                .linearGradient(
                                    colors: [.indigo, .purple],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .symbolRenderingMode(.hierarchical)
                            .padding(.bottom, 6)
                        
                        Text("How to Use PDF Merger")
                            .font(.system(.title2, design: .rounded))
                            .fontWeight(.bold)
                            .foregroundColor(.primary)
                        
                        Text("Simple steps to combine and organize your PDFs")
                            .font(.system(.callout, design: .rounded))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 28)
                    
                    // Instructions
                    VStack(spacing: 14) {
                        InstructionCard(
                            number: 1,
                            icon: "plus.circle.fill",
                            title: "Import PDFs",
                            description: "Tap the + button to select PDF documents from your device"
                        )
                        
                        InstructionCard(
                            number: 2,
                            icon: "hand.tap",
                            title: "Select Pages",
                            description: "Tap the circle next to any page to select it for bulk actions"
                        )
                        
                        InstructionCard(
                            number: 3,
                            icon: "arrow.up.arrow.down",
                            title: "Drag to Reorder",
                            description: "Drag pages up or down to arrange them in your desired order"
                        )
                        
                        InstructionCard(
                            number: 4,
                            icon: "trash",
                            title: "Delete Pages",
                            description: "Remove unwanted pages using the delete button or trash icon"
                        )
                        
                        InstructionCard(
                            number: 5,
                            icon: "square.and.arrow.up",
                            title: "Export",
                            description: "Save your organized PDF with a custom filename and location"
                        )
                    }
                    .padding(.horizontal, 18)
                    
                    Spacer(minLength: 30)
                }
                .padding(.vertical, 24)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .background(Color(.systemGroupedBackground))
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

struct InstructionCard: View {
    let number: Int
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Number circle
            ZStack {
                Circle()
                    .fill(
                        .linearGradient(
                            colors: [.indigo.opacity(0.15), .purple.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 34, height: 34)
                
                Text("\(number)")
                    .font(.system(.callout, design: .rounded))
                    .fontWeight(.bold)
                    .foregroundColor(.indigo)
            }
            
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Image(systemName: icon)
                        .font(.subheadline)
                        .foregroundColor(.indigo)
                        .frame(width: 18)
                        .symbolRenderingMode(.hierarchical)
                    
                    Text(title)
                        .font(.system(.subheadline, design: .rounded))
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                }
                
                Text(description)
                    .font(.system(.caption, design: .rounded))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 25)
            }
            
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.04), radius: 3, x: 0, y: 1)
        )
    }
}

// MARK: - Preview

#Preview {
    PDFMergerOrganizerView()
}
