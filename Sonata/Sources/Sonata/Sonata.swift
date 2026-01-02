import SwiftUI
import SwiftClaude
import UniformTypeIdentifiers
import System

#if canImport(UIKit)
import UIKit
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

extension EnvironmentValues {
    var claudeClient: ClaudeClient? {
        get { self[ClaudeClientKey.self] }
        set { self[ClaudeClientKey.self] = newValue }
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

    var body: some View {
        GeometryReader { proxy in
            ScrollViewReader { reader in
                ScrollView {
                    ForEach(Array(conversation.messages.values)) { message in
                        MessageView(message: message)
                            .environment(\.claudeClient, conversation.client)
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
                    // Attachment button
                    Button {
                        showingFilePicker = true
                    } label: {
                        Label("Attach file", systemImage: "paperclip")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .imageScale(.medium)
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
