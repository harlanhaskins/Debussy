//
//  ClaudeController.swift
//
//
//  Created by Harlan Haskins on 12/28/25.
//

import SwiftClaude
import SwiftUI
import Foundation
import System

@MainActor @Observable
final class ClaudeController {
    private let apiKey: String
    private let customInstructions: String
    private let mcpManager: MCPManager?
    var conversations = [Conversation]()

    init(apiKey: String, customInstructions: String = "", mcpServers: [MCPServerConfiguration] = []) async {
        self.apiKey = apiKey
        self.customInstructions = customInstructions

        // Create and start MCP manager if servers are configured
        if !mcpServers.isEmpty {
            let mcpConfig = MCPConfiguration(mcpServers: Dictionary(
                uniqueKeysWithValues: mcpServers.map { server in
                    (server.name, MCPServerConfig(url: server.url))
                }
            ))
            let manager = MCPManager(configuration: mcpConfig)
            await manager.start()
            self.mcpManager = manager
        } else {
            self.mcpManager = nil
        }
    }

    private func makeSystemPrompt(filesDir: FilePath) -> String {
        var systemPrompt = """
        You are running in a sandboxed Apple platform environment with file system access.

        # Available Directories

        **Working Directory (scratch files):**
        \(filesDir.string)

        **Temporary Directory:**
        \(FilePath(URL.temporaryDirectory.path).string)

        **OS Version**
        \(ProcessInfo.processInfo.operatingSystemVersionString)

        # File System Notes

        - You have full read/write access to the working directory and temporary directory
        - You can attempt to access files outside these directories, but the OS will likely deny access due to sandboxing
        - All file paths should be absolute (starting with /)
        - The working directory persists between sessions; temporary directory may be cleared

        # Available Tools

        You have access to file operations (Read, Write, Update, List, Grep, Glob), web access (Fetch, WebSearch), JavaScript execution, HTML canvas rendering (WebCanvas), location services (UserLocation, MapSearch), and SubAgent (for spawning parallel sub-tasks).
        """

        // Add custom instructions if provided
        if !customInstructions.isEmpty {
            systemPrompt += "\n\n# Custom Instructions\n\n\(customInstructions)"
        }

        return systemPrompt
    }

    private func makeTools(
        workingDirectory: FilePath,
        locationController: LocationController,
        contactsController: ContactsController,
        subAgentCallback: @escaping SubAgentTool.OutputCallback,
        toolHistoryProvider: @escaping @MainActor () -> [SwiftClaude.ToolExecutionInfo]
    ) -> Tools {
        Tools {
            ReadTool()
            WriteTool()
            UpdateTool()
            ListTool()
            GrepTool()
            GlobTool()
            FetchTool()
            WebSearchTool()
            JavaScriptTool(historyProvider: toolHistoryProvider)
            WebCanvasTool(workingDirectory: workingDirectory)
            UserLocationTool(locationController: locationController)
            MapSearchTool(locationController: locationController)
            ContactsSearchTool(contactsController: contactsController)
            AddToContactsTool(contactsController: contactsController)
            SubAgentTool(apiKey: apiKey, outputCallback: subAgentCallback)
        }
    }

    private func makeClaudeClient(
        systemPrompt: String,
        filesDir: FilePath,
        tools: Tools
    ) async throws -> ClaudeClient {
        try await ClaudeClient(
            options: ClaudeAgentOptions(
                systemPrompt: systemPrompt,
                apiKey: apiKey,
                workingDirectory: filesDir,
                model: defaultClaudeModel,
                compactionEnabled: true,
                compactionTokenThreshold: 120_000,
                keepRecentTokens: 50_000
            ),
            tools: tools,
            mcpManager: mcpManager
        )
    }

    private func setupClientAndConversation(
        conversationId: UUID,
        filesDir: FilePath
    ) async throws -> Conversation {
        let systemPrompt = makeSystemPrompt(filesDir: filesDir)
        let locationController = LocationController()
        let contactsController = ContactsController()

        // Create a holder for the conversation reference
        @MainActor
        final class ConversationHolder {
            var conversation: Conversation?
        }
        let holder = ConversationHolder()

        // Create SubAgent callback
        let subAgentCallback: @Sendable (SubAgentOutput) -> Void = { output in
            guard case .toolCall(let toolName, let summary) = output.event else { return }
            Task { @MainActor in
                holder.conversation?.handleSubAgentToolCall(taskId: output.taskId, toolName: toolName, summary: summary)
            }
        }

        // Create tool history provider for JavaScript tool
        let toolHistoryProvider: @MainActor () -> [SwiftClaude.ToolExecutionInfo] = {
            holder.conversation?.toolExecutionHistory() ?? []
        }

        let tools = makeTools(
            workingDirectory: filesDir,
            locationController: locationController,
            contactsController: contactsController,
            subAgentCallback: subAgentCallback,
            toolHistoryProvider: toolHistoryProvider
        )
        let client = try await makeClaudeClient(systemPrompt: systemPrompt, filesDir: filesDir, tools: tools)

        // Setup permission hooks
        await setupLocationPermissionHook(client: client, locationController: locationController)
        await setupMapSearchPermissionHook(client: client, locationController: locationController)
        await setupContactsPermissionHook(client: client, contactsController: contactsController)
        await setupAddToContactsPermissionHook(client: client, contactsController: contactsController)

        let conversation = await Conversation(client: client, id: conversationId)
        holder.conversation = conversation

        return conversation
    }

    func createConversation() async -> Conversation {
        let conversationId = UUID()
        let filesDir = conversationFilesDirectory(for: conversationId)

        // Create files directory
        try? FileManager.default.createDirectory(at: URL(filePath: filesDir)!, withIntermediateDirectories: true)

        let conversation = try! await setupClientAndConversation(
            conversationId: conversationId,
            filesDir: filesDir
        )

        conversations.insert(conversation, at: 0)
        return conversation
    }

    private func conversationFilesDirectory(for conversationId: UUID) -> FilePath {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileURL = documentsURL
            .appendingPathComponent("conversations")
            .appendingPathComponent(conversationId.uuidString)
            .appendingPathComponent("files")
        return FilePath(fileURL.path)
    }

    private func conversationDirectory(for conversationId: UUID) -> URL {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsURL
            .appendingPathComponent("conversations")
            .appendingPathComponent(conversationId.uuidString)
    }

    func deleteConversation(id: UUID) async {
        // Remove from array
        conversations.removeAll { $0.id == id }

        // Delete folder
        let conversationDir = conversationDirectory(for: id)
        try? FileManager.default.removeItem(at: conversationDir)

        // Update manifest
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let manifestURL = documentsURL.appendingPathComponent("conversations/conversations.json")
        let manifestPath = FilePath(manifestURL.path)

        guard FileManager.default.fileExists(atPath: manifestURL.path),
              var manifest = try? loadJSON(from: manifestPath) as ConversationsManifest else {
            return
        }

        manifest.conversations.removeAll { $0.id == id }

        try? saveJSON(manifest, to: manifestPath)
    }

    func loadPersistedConversations() async {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let manifestURL = documentsURL.appendingPathComponent("conversations/conversations.json")
        let manifestPath = FilePath(manifestURL.path)

        guard FileManager.default.fileExists(atPath: manifestURL.path),
              let manifest = try? loadJSON(from: manifestPath) as ConversationsManifest else {
            return
        }

        for metadata in manifest.conversations {
            do {
                let conversationDir = documentsURL.appendingPathComponent("conversations/\(metadata.id.uuidString)")
                let sessionURL = conversationDir.appendingPathComponent("session.json")

                guard FileManager.default.fileExists(atPath: sessionURL.path) else {
                    continue
                }

                let filesDir = conversationFilesDirectory(for: metadata.id)

                // Create files directory if it doesn't exist
                try? FileManager.default.createDirectory(at: URL(filePath: filesDir)!, withIntermediateDirectories: true)

                let conversation = try await setupClientAndConversation(
                    conversationId: metadata.id,
                    filesDir: filesDir
                )

                let sessionData = try Data(contentsOf: sessionURL)
                try await conversation.client.importSession(from: sessionData)
                await conversation.rebuildMessagesFromHistory()

                conversations.append(conversation)
            } catch {
                // Skip conversations that fail to load
            }
        }
    }
}
