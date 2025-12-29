//
//  ClaudeController.swift
//
//
//  Created by Harlan Haskins on 12/28/25.
//

import SwiftClaude
import SwiftUI
import Foundation

@MainActor @Observable
final class ClaudeController {
    private let apiKey: String
    var conversations = [Conversation]()

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func createConversation() async -> Conversation {
        let conversationId = UUID()
        let filesDir = conversationFilesDirectory(for: conversationId)

        // Create files directory
        try? FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)

        let systemPrompt = """
        You are running in a sandboxed Apple platform environment with file system access.

        # Available Directories

        **Working Directory (scratch files):**
        \(filesDir.path)

        **Temporary Directory:**
        \(URL.temporaryDirectory.path)
        
        **OS Version**
        \(ProcessInfo.processInfo.operatingSystemVersionString)

        # File System Notes

        - You have full read/write access to the working directory and temporary directory
        - You can attempt to access files outside these directories, but the OS will likely deny access due to sandboxing
        - All file paths should be absolute (starting with /)
        - The working directory persists between sessions; temporary directory may be cleared

        # Available Tools

        You have access to file operations (Read, Write, Update, List, Grep, Glob), web access (Fetch, WebSearch), JavaScript execution, and HTML canvas rendering (WebCanvas).
        """

        let client = try! await ClaudeClient(
            options: ClaudeAgentOptions(
                systemPrompt: systemPrompt,
                apiKey: apiKey,
                model: "claude-sonnet-4-5-20250929",
                workingDirectory: filesDir,
                compactionEnabled: true,
                compactionTokenThreshold: 120_000,
                keepRecentTokens: 50_000
            ),
            tools: Tools {
                ReadTool()
                WriteTool()
                UpdateTool()
                ListTool()
                GrepTool()
                GlobTool()
                FetchTool()
                WebSearchTool()
                JavaScriptTool()
                WebCanvasTool(workingDirectory: filesDir)
            }
        )

        let conversation = await Conversation(client: client, id: conversationId)
        conversations.insert(conversation, at: 0)
        return conversation
    }

    private func conversationFilesDirectory(for conversationId: UUID) -> URL {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsURL
            .appendingPathComponent("conversations")
            .appendingPathComponent(conversationId.uuidString)
            .appendingPathComponent("files")
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

        guard FileManager.default.fileExists(atPath: manifestURL.path),
              let data = try? Data(contentsOf: manifestURL),
              var manifest = try? JSONDecoder().decode(ConversationsManifest.self, from: data) else {
            return
        }

        manifest.conversations.removeAll { $0.id == id }

        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: manifestURL)
        }
    }

    func loadPersistedConversations() async {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let manifestURL = documentsURL.appendingPathComponent("conversations/conversations.json")

        guard FileManager.default.fileExists(atPath: manifestURL.path),
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(ConversationsManifest.self, from: data) else {
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
                try? FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)

                let systemPrompt = """
                You are running in a sandboxed environment with file system access.

                # Available Directories

                **Working Directory (scratch files):**
                \(filesDir.path)

                **Temporary Directory:**
                \(URL.temporaryDirectory.path)

                # File System Notes

                - You have full read/write access to the working directory and temporary directory
                - You can attempt to access files outside these directories, but the OS will likely deny access due to sandboxing
                - All file paths should be absolute (starting with /)
                - The working directory persists between sessions; temporary directory may be cleared

                # Available Tools

                You have access to file operations (Read, Write, Update, List, Grep, Glob), web access (Fetch, WebSearch), JavaScript execution, and HTML canvas rendering (WebCanvas).
                """

                let client = try await ClaudeClient(
                    options: ClaudeAgentOptions(
                        systemPrompt: systemPrompt,
                        apiKey: apiKey,
                        model: "claude-sonnet-4-5-20250929",
                        workingDirectory: filesDir,
                        compactionEnabled: true,
                        compactionTokenThreshold: 120_000,
                        keepRecentTokens: 50_000
                    ),
                    tools: Tools {
                        ReadTool()
                        WriteTool()
                        UpdateTool()
                        ListTool()
                        GrepTool()
                        GlobTool()
                        FetchTool()
                        WebSearchTool()
                        JavaScriptTool()
                        WebCanvasTool(workingDirectory: filesDir)
                    }
                )

                let conversation = await Conversation(client: client, id: metadata.id)

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
