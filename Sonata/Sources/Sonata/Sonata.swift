import SwiftUI
import SwiftClaude
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#endif

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

@MainActor
@Observable
@MainActor @Observable
class SettingsManager {
    private static let apiKeyKey = "anthropic_api_key"
    private static let customInstructionsKey = "custom_instructions"
    private static let mcpServersKey = "mcp_servers"

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
            if let encoded = try? JSONEncoder().encode(mcpServers) {
                UserDefaults.standard.set(encoded, forKey: Self.mcpServersKey)
            }
        }
    }

    init() {
        self.apiKey = UserDefaults.standard.string(forKey: Self.apiKeyKey) ?? ""
        self.customInstructions = UserDefaults.standard.string(forKey: Self.customInstructionsKey) ?? ""

        if let data = UserDefaults.standard.data(forKey: Self.mcpServersKey),
           let servers = try? JSONDecoder().decode([MCPServerConfiguration].self, from: data) {
            self.mcpServers = servers
        } else {
            self.mcpServers = []
        }
    }

    var hasAPIKey: Bool {
        !apiKey.isEmpty
    }
}

@MainActor
struct APIKeySheet: View {
    var apiKeyManager: APIKeyManager
    @Binding var isPresented: Bool
    @State private var apiKeyInput: String = ""
    var onSave: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("API Key", text: $apiKeyInput)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                } header: {
                    Text("Anthropic API Key")
                } footer: {
                    Text("Enter your Anthropic API key. You can find it at console.anthropic.com")
                }

                if apiKeyManager.hasAPIKey {
                    Section {
                        Button(role: .destructive) {
                            apiKeyManager.apiKey = ""
                            apiKeyInput = ""
                        } label: {
                            Text("Remove Saved API Key")
                        }
                    }
                }
            }
            .navigationTitle("API Key")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        apiKeyManager.apiKey = apiKeyInput
                        isPresented = false
                        onSave()
                    }
                    .disabled(apiKeyInput.isEmpty)
                }
            }
            .onAppear {
                apiKeyInput = apiKeyManager.apiKey
            }
        }
    }
}

@MainActor
public struct ContentView: View {
    @Environment(\.colorScheme) var colorScheme
    @State var apiKeyManager = APIKeyManager()
    @State var controller: ClaudeController?
    @State var selectedConversation: Conversation.ID?
    @State var showingAPIKeySheet = false
    @State var apiKeyInput = ""
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
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
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
                            showingAPIKeySheet = true
                        } label: {
                            Image(systemName: "key.fill")
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
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        .sheet(isPresented: $showingAPIKeySheet) {
            APIKeySheet(apiKeyManager: apiKeyManager, isPresented: $showingAPIKeySheet) {
                Task {
                    await initializeController()
                }
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
        guard apiKeyManager.hasAPIKey else {
            showingAPIKeySheet = true
            return
        }

        if controller == nil {
            controller = ClaudeController(apiKey: apiKeyManager.apiKey)
        }

        await controller?.loadPersistedConversations()

        if controller?.conversations.isEmpty == true {
            selectedConversation = await controller?.createConversation().id
        } else {
            selectedConversation = controller?.conversations.first?.id
        }
    }
}
