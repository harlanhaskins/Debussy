import SwiftUI
import SwiftClaude
import UniformTypeIdentifiers
import System
import PhotosUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - JSON File Utilities

func saveJSON<T: Encodable>(_ value: T, to path: FilePath) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    try data.write(to: URL(filePath: path)!)
}

func loadJSON<T: Decodable>(from path: FilePath) throws -> T {
    let data = try Data(contentsOf: URL(filePath: path)!)
    let decoder = JSONDecoder()
    return try decoder.decode(T.self, from: data)
}

// MARK: - Environment Keys

private struct ClaudeClientKey: EnvironmentKey {
    static let defaultValue: ClaudeClient? = nil
}

private struct UploadingFilesKey: EnvironmentKey {
    static let defaultValue: Set<String> = []
}

extension EnvironmentValues {
    var claudeClient: ClaudeClient? {
        get { self[ClaudeClientKey.self] }
        set { self[ClaudeClientKey.self] = newValue }
    }

    var uploadingFiles: Set<String> {
        get { self[UploadingFilesKey.self] }
        set { self[UploadingFilesKey.self] = newValue }
    }
}

@MainActor
struct ConversationView: View {
    var conversation: Conversation
    @State var message = ""
    @State var error: Error?
    @State var sendingMessageTask: Task<Void, Never>?
    @State var sendingMessageText: String?
    @State var selectedAttachments: [FileAttachment] = []
    @State var showingFilePicker = false
    @State var showingPhotoPicker = false
    @State var selectedPhotoItems: [PhotosPickerItem] = []
    @State var showingCamera = false

    var body: some View {
        GeometryReader { proxy in
            ScrollViewReader { reader in
                ScrollView {
                    ForEach(Array(conversation.messages.values)) { message in
                        MessageView(message: message)
                            .environment(\.claudeClient, conversation.client)
                            .environment(\.uploadingFiles, conversation.uploadingFiles)
                    }
                }
                .onAppear {
                    if let lastMessage = conversation.messages.values.last {
                        reader.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
                .onChange(of: conversation.messages.keys.last) {
                    if let lastMessage = conversation.messages.values.last {
                        withAnimation(.snappy) {
                            reader.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .contentMargins(8, for: .scrollContent)
        }
        .safeAreaBar(edge: .bottom) {
            VStack(spacing: 8) {
                // Attachment previews
                if !selectedAttachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(selectedAttachments) { attachment in
                                AttachmentPreviewChip(
                                    attachment: attachment,
                                    onRemove: {
                                        selectedAttachments.removeAll { $0.id == attachment.id }
                                    }
                                )
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                }

                HStack(alignment: .bottom, spacing: 8) {
                    // Attachment menu button
                    Menu {
                        Button {
                            showingPhotoPicker = true
                        } label: {
                            Label("Choose from Photos", systemImage: "photo.on.rectangle")
                        }

                        #if canImport(UIKit)
                        Button {
                            showingCamera = true
                        } label: {
                            Label("Take Photo", systemImage: "camera")
                        }
                        #endif

                        Button {
                            showingFilePicker = true
                        } label: {
                            Label("Choose File", systemImage: "folder")
                        }
                    } label: {
                        Label("Attach", systemImage: "plus")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .menuOrder(.fixed)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .frame(width: 44, height: 44)
                    .disabled(sendingMessageTask != nil)

                    TextField("Message", text: $message, axis: .vertical)
                        .onSubmit(sendCurrentMessage)
                        .submitLabel(.send)
                        .textFieldStyle(.plain)
                        .disabled(sendingMessageTask != nil)
                        .lineLimit(1...10)
                        .frame(minHeight: 24)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glassEffect(in: .rect(cornerRadius: 22))

                    ZStack {
                        if sendingMessageTask == nil {
                            Button(action: sendCurrentMessage) {
                                Label("Send message", systemImage: "arrow.up")
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                            .buttonStyle(.glassProminent)
                            .buttonBorderShape(.circle)
                            .imageScale(.large)
                            .tint(Color.claudeOrange)
                            .disabled(message.isEmpty && selectedAttachments.isEmpty)
                        } else {
                            Button {
                                sendingMessageTask?.cancel()
                                sendingMessageTask = nil
                                if let sendingMessageText {
                                    message = sendingMessageText
                                    self.sendingMessageText = nil
                                }
                            } label: {
                                Label("Stop", systemImage: "stop.fill")
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                            .buttonStyle(.glassProminent)
                            .buttonBorderShape(.circle)
                            .imageScale(.large)
                            .tint(Color.claudeOrange)
                        }
                    }
                    .frame(width: 44, height: 44)
                }
                .padding(8)
            }
        }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            handleFileSelection(result)
        }
        .photosPicker(
            isPresented: $showingPhotoPicker,
            selection: $selectedPhotoItems,
            maxSelectionCount: 10,
            matching: .images
        )
        .onChange(of: selectedPhotoItems) { oldValue, newValue in
            handlePhotoSelection(newValue)
        }
        #if canImport(UIKit)
        .fullScreenCover(isPresented: $showingCamera) {
            CameraView { image in
                handleCapturedPhoto(image)
            }
        }
        #endif
    }

    func sendCurrentMessage() {
        guard !message.isEmpty || !selectedAttachments.isEmpty else { return }
        error = nil
        let messageText = self.message.isEmpty ? " " : self.message  // Need at least one character for text content
        let attachments = self.selectedAttachments
        self.message = ""
        self.selectedAttachments = []
        sendingMessageText = messageText
        sendingMessageTask = Task { @MainActor in
            do {
                try await conversation.sendMessage(text: messageText, attachments: attachments)
            } catch {
                self.error = error
            }
            self.sendingMessageTask = nil
        }
    }

    func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            Task {
                for url in urls {
                    do {
                        // Get security-scoped access
                        guard url.startAccessingSecurityScopedResource() else {
                            print("Failed to access file: \(url)")
                            continue
                        }
                        defer { url.stopAccessingSecurityScopedResource() }

                        // Copy file to conversation directory
                        let attachment = try await conversation.fileManager.copyFile(
                            from: url,
                            toMessageId: UUID()  // Temporary ID, will be set when message is created
                        )
                        selectedAttachments.append(attachment)
                    } catch {
                        print("Failed to add attachment: \(error)")
                    }
                }
            }
        case .failure(let error):
            print("File selection failed: \(error)")
        }
    }

    private func downsampleImageData(_ data: Data, maxDimension: CGFloat = 1000) -> Data? {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else {
            print("❌ Failed to create image source")
            return nil
        }

        // Get original image properties to determine if downsampling is needed
        guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat else {
            print("❌ Failed to get image properties")
            return nil
        }

        print("📸 Original size: \(width) × \(height)")

        let maxOriginalDimension = max(width, height)

        // If image is already small enough, return original data
        if maxOriginalDimension <= maxDimension {
            print("📸 Image already small enough, no downsampling needed")
            return data
        }

        // Calculate thumbnail size
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ]

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            print("❌ Failed to create thumbnail")
            return nil
        }

        print("📸 Downsampled size: \(thumbnail.width) × \(thumbnail.height)")

        // Convert to JPEG data
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(mutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            print("❌ Failed to create image destination")
            return nil
        }

        let compressionOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.9
        ]
        CGImageDestinationAddImage(destination, thumbnail, compressionOptions as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            print("❌ Failed to finalize image destination")
            return nil
        }

        print("📸 Downsampled data: \(mutableData.length) bytes")
        return mutableData as Data
    }

    func handlePhotoSelection(_ items: [PhotosPickerItem]) {
        print("📸 handlePhotoSelection called with \(items.count) items")
        Task {
            for item in items {
                do {
                    print("📸 Loading photo data...")
                    // Load image data
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        print("❌ Failed to load photo data")
                        continue
                    }
                    print("📸 Loaded \(data.count) bytes")

                    // Downsample using CGImageSource
                    guard let downsampledData = downsampleImageData(data) else {
                        print("❌ Failed to downsample image")
                        continue
                    }

                    // Save to temporary file
                    let tempURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension("jpg")
                    print("📸 Saving to temp: \(tempURL.path)")
                    try downsampledData.write(to: tempURL)

                    // Copy to conversation directory
                    print("📸 Copying to conversation directory...")
                    let attachment = try await conversation.fileManager.copyFile(
                        from: tempURL,
                        toMessageId: UUID()
                    )
                    print("📸 Created attachment: \(attachment.path.string)")
                    print("📸 MIME type: \(attachment.mimeType)")
                    print("📸 File size: \(attachment.fileSize)")
                    selectedAttachments.append(attachment)
                    print("📸 Total attachments: \(selectedAttachments.count)")

                    // Clean up temp file
                    try? FileManager.default.removeItem(at: tempURL)
                } catch {
                    print("❌ Failed to add photo: \(error)")
                }
            }
            // Clear selection
            selectedPhotoItems = []
        }
    }

    #if canImport(UIKit)
    func handleCapturedPhoto(_ image: UIImage) {
        Task {
            do {
                // Convert to JPEG data first
                guard let originalData = image.jpegData(compressionQuality: 1.0) else {
                    print("Failed to convert image to JPEG")
                    return
                }

                // Downsample using CGImageSource
                guard let downsampledData = downsampleImageData(originalData) else {
                    print("❌ Failed to downsample captured photo")
                    return
                }

                // Save to temporary file
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("jpg")
                try downsampledData.write(to: tempURL)

                // Copy to conversation directory
                let attachment = try await conversation.fileManager.copyFile(
                    from: tempURL,
                    toMessageId: UUID()
                )
                selectedAttachments.append(attachment)

                // Clean up temp file
                try? FileManager.default.removeItem(at: tempURL)
            } catch {
                print("Failed to save captured photo: \(error)")
            }
        }
    }
    #elseif canImport(AppKit)
    func handleCapturedPhoto(_ image: NSImage) {
        Task {
            do {
                // Convert to JPEG data first
                guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    print("Failed to convert image")
                    return
                }
                let bitmap = NSBitmapImageRep(cgImage: cgImage)
                guard let originalData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 1.0]) else {
                    print("Failed to convert image to JPEG")
                    return
                }

                // Downsample using CGImageSource
                guard let downsampledData = downsampleImageData(originalData) else {
                    print("❌ Failed to downsample captured photo")
                    return
                }

                // Save to temporary file
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("jpg")
                try downsampledData.write(to: tempURL)

                // Copy to conversation directory
                let attachment = try await conversation.fileManager.copyFile(
                    from: tempURL,
                    toMessageId: UUID()
                )
                selectedAttachments.append(attachment)

                // Clean up temp file
                try? FileManager.default.removeItem(at: tempURL)
            } catch {
                print("Failed to save captured photo: \(error)")
            }
        }
    }
    #endif
}

// MARK: - Attachment Preview Chip

struct AttachmentPreviewChip: View {
    let attachment: FileAttachment
    let onRemove: () -> Void
    @Environment(\.colorScheme) var colorScheme

    var borderColor: Color {
        colorScheme == .dark ? .darkBorder : .lightBorder
    }

    var iconName: String {
        if attachment.mimeType.hasPrefix("image/") {
            return "photo"
        } else if attachment.mimeType == "application/pdf" {
            return "doc.richtext"
        } else {
            return "doc"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(attachment.fileName)
                .font(.caption)
                .lineLimit(1)

            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.1), in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(borderColor, lineWidth: 0.5)
        }
    }
}

@MainActor @Observable
class SettingsManager {
    private static let apiKeyKey = "anthropic_api_key"
    private static let customInstructionsKey = "custom_instructions"

    private var mcpServersFilePath: FilePath {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileURL = documentsURL.appendingPathComponent("mcp-servers.json")
        return FilePath(fileURL.path)
    }

    var apiKey: String {
        didSet {
            UserDefaults.standard.set(apiKey, forKey: Self.apiKeyKey)
        }
    }

    var customInstructions: String {
        didSet {
            UserDefaults.standard.set(customInstructions, forKey: Self.customInstructionsKey)
        }
    }

    var mcpServers: [MCPServerConfiguration] {
        didSet {
            saveMCPServers()
        }
    }

    init() {
        self.apiKey = UserDefaults.standard.string(forKey: Self.apiKeyKey) ?? ""
        self.customInstructions = UserDefaults.standard.string(forKey: Self.customInstructionsKey) ?? ""
        self.mcpServers = []
        loadMCPServers()
    }

    private func saveMCPServers() {
        do {
            try saveJSON(mcpServers, to: mcpServersFilePath)
        } catch {
            print("Failed to save MCP servers: \(error)")
        }
    }

    private func loadMCPServers() {
        guard FileManager.default.fileExists(atPath: mcpServersFilePath.string) else {
            return
        }

        do {
            mcpServers = try loadJSON(from: mcpServersFilePath)
        } catch {
            print("Failed to load MCP servers: \(error)")
        }
    }

    var hasAPIKey: Bool {
        !apiKey.isEmpty
    }

    func deleteAllData() {
        // Clear UserDefaults
        UserDefaults.standard.removeObject(forKey: Self.apiKeyKey)
        UserDefaults.standard.removeObject(forKey: Self.customInstructionsKey)

        // Delete MCP servers file
        try? FileManager.default.removeItem(at: URL(filePath: mcpServersFilePath)!)

        // Delete conversations directory
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let conversationsURL = documentsURL.appendingPathComponent("conversations")
        try? FileManager.default.removeItem(at: conversationsURL)

        // Reset in-memory state
        apiKey = ""
        customInstructions = ""
        mcpServers = []
    }
}

@MainActor
public struct ContentView: View {
    @Environment(\.colorScheme) var colorScheme
    @State var settingsManager = SettingsManager()
    @State var controller: ClaudeController?
    @State var selectedConversation: Conversation.ID?
    @State var showingSettings = false
    @State var conversationToDelete: Conversation.ID?
    public init() {}

    public var body: some View {
        NavigationSplitView {
            conversationList
        } detail: {
            conversationDetail
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(
                apiKey: $settingsManager.apiKey,
                customInstructions: $settingsManager.customInstructions,
                mcpServers: $settingsManager.mcpServers
            ) {
                handleDeleteAllData()
            }
        }
        .task {
            await initializeController()
        }
        .confirmationDialog(
            "Delete this conversation?",
            isPresented: .init(
                get: { conversationToDelete != nil },
                set: { if !$0 { conversationToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = conversationToDelete {
                    Task {
                        await controller?.deleteConversation(id: id)
                        if selectedConversation == id {
                            selectedConversation = controller?.conversations.first?.id
                        }
                    }
                    conversationToDelete = nil
                }
            }
            Button("Cancel", role: .cancel) {
                conversationToDelete = nil
            }
        } message: {
            Text("This will permanently delete the conversation and all its files.")
        }
    }

    @ViewBuilder
    private var conversationList: some View {
        if let controller {
            List(controller.conversations, selection: $selectedConversation) { conversation in
                NavigationLink(value: conversation.id) {
                    conversationRow(for: conversation)
                }
            }
            .navigationTitle("Conversations")
            .toolbarTitleDisplayMode(.inlineLarge)
            .safeAreaBar(edge: .bottom) {
                Button {
                    Task {
                        let conv = await controller.createConversation()
                        withAnimation {
                            selectedConversation = conv.id
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                        .imageScale(.large)
                }
                .buttonStyle(.glass)
                .tint(.claudeOrange)
                .buttonBorderShape(.circle)
                .padding(8)
            }
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                    }
                }
            }
            #if os(iOS)
            .containerBackground(
                colorScheme == .dark ? Color.darkBackground : Color.lightBackground,
                for: .navigation
            )
            #endif
        } else {
            ProgressView()
        }
    }

    @ViewBuilder
    private var conversationDetail: some View {
        if let controller, let selectedConversation, let conversation = controller.conversations.first(where: { $0.id == selectedConversation }) {
            NavigationStack {
                ConversationView(conversation: conversation)
                    .navigationTitle("Claude")
                    #if os(iOS)
                    .containerBackground(
                        colorScheme == .dark ? Color.darkBackground : Color.lightBackground,
                        for: .navigation
                    )
                    #endif
                    .toolbarTitleDisplayMode(.inlineLarge)
            }
        }
    }

    @ViewBuilder
    private func conversationRow(for conversation: Conversation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(conversation.title)
                .lineLimit(1)
            Text(conversation.lastMessageTimestamp, style: .date)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                conversationToDelete = conversation.id
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func initializeController() async {
        guard settingsManager.hasAPIKey else {
            showingSettings = true
            return
        }

        if controller == nil {
            controller = await ClaudeController(
                apiKey: settingsManager.apiKey,
                customInstructions: settingsManager.customInstructions,
                mcpServers: settingsManager.mcpServers
            )
        }

        await controller?.loadPersistedConversations()

        if controller?.conversations.isEmpty == true {
            selectedConversation = await controller?.createConversation().id
        } else {
            selectedConversation = controller?.conversations.first?.id
        }
    }

    private func handleDeleteAllData() {
        settingsManager.deleteAllData()
        controller = nil
        selectedConversation = nil
        showingSettings = true
    }
}

// MARK: - Camera View

#if canImport(UIKit)
struct CameraView: UIViewControllerRepresentable {
    @Environment(\.dismiss) var dismiss
    let onCapture: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraView

        init(_ parent: CameraView) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onCapture(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
#endif
