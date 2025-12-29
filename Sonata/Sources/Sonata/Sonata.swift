import SwiftUI
import SwiftClaude
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#endif

// MARK: - JSON File Utilities

func saveJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    try data.write(to: url)
}

func loadJSON<T: Decodable>(from url: URL) throws -> T {
    let data = try Data(contentsOf: url)
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
            HStack {
                TextField("Message", text: $message)
                    .onSubmit(sendCurrentMessage)
                    .submitLabel(.send)
                    .textFieldStyle(.plain)
                    .disabled(sendingMessageTask != nil)
                if sendingMessageTask == nil {
                    Button("Send message", systemImage: "arrow.up", action: sendCurrentMessage)
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.circle)
                        .imageScale(.large)
                        .tint(Color.claudeOrange)
                        .disabled(message.isEmpty)
                } else {
                    Button("Stop", systemImage: "stop.fill") {
                        sendingMessageTask?.cancel()
                        sendingMessageTask = nil
                        if let sendingMessageText {
                            message = sendingMessageText
                            self.sendingMessageText = nil
                        }
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .imageScale(.large)
                    .tint(Color.claudeOrange)
                }
            }
            .padding(10)
            .glassEffect(in: .capsule)
            .padding(8)
        }
    }

    func sendCurrentMessage() {
        guard !message.isEmpty else { return }
        error = nil
        let message = self.message
        self.message = ""
        sendingMessageText = message
        sendingMessageTask = Task { @MainActor in
            do {
                try await conversation.sendMessage(text: message)
            } catch {
                self.error = error
            }
            self.sendingMessageTask = nil
        }
    }
}

@MainActor @Observable
class SettingsManager {
    private static let apiKeyKey = "anthropic_api_key"
    private static let customInstructionsKey = "custom_instructions"

    private var mcpServersFileURL: URL {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsURL.appendingPathComponent("mcp-servers.json")
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
            try saveJSON(mcpServers, to: mcpServersFileURL)
        } catch {
            print("Failed to save MCP servers: \(error)")
        }
    }

    private func loadMCPServers() {
        guard FileManager.default.fileExists(atPath: mcpServersFileURL.path) else {
            return
        }

        do {
            mcpServers = try loadJSON(from: mcpServersFileURL)
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
        try? FileManager.default.removeItem(at: mcpServersFileURL)

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
        NavigationSplitView(preferredCompactColumn: .constant(.detail)) {
            if let controller {
                List(controller.conversations, selection: $selectedConversation) { conversation in
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
        } detail: {
            ZStack {
                if let controller, let selectedConversation, let conversation = controller.conversations.first(where: { $0.id == selectedConversation }) {
                    ConversationView(conversation: conversation)
                }
            }
            .navigationTitle(Text("Claude"))
            #if os(iOS)
            .containerBackground(
                colorScheme == .dark ? Color.darkBackground : Color.lightBackground,
                for: .navigation
            )
            #endif
            .toolbarTitleDisplayMode(.inlineLarge)
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

    private func initializeController() async {
        guard settingsManager.hasAPIKey else {
            showingSettings = true
            return
        }

        if controller == nil {
            controller = ClaudeController(
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
