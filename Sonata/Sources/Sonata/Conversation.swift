//
//  Conversation.swift
//
//
//  Created by Harlan Haskins on 12/28/25.
//

import SwiftClaude
import SwiftUI
import Foundation
import Collections

@MainActor @Observable
final class Conversation: Identifiable {
    let id: UUID
    let client: ClaudeClient

    init(client: ClaudeClient, id: UUID = UUID()) async {
        self.client = client
        self.id = id
        await setupHooks()
    }

    var messages = OrderedDictionary<UUID, ConversationMessage>()

    // Track tool executions by ID - public so MessageView can look them up
    var toolExecutions: [String: ToolExecution] = [:]

    /// Title for the conversation based on the first user message
    var title: String {
        guard let firstUserMessage = messages.values.first(where: { $0.kind == .user }) else {
            return "New Conversation"
        }

        // Get text content from first user message
        let text = firstUserMessage.content.compactMap { block in
            if case .text(let content) = block {
                return content
            }
            return nil
        }.joined()

        return text.isEmpty ? "New Conversation" : text
    }

    private func setupHooks() async {
        // Register hook for tool execution start
        await client.addHook(.beforeToolExecution) { [weak self] (context: BeforeToolExecutionContext) async throws -> Void in
            await self?.handleBeforeToolExecution(context)
        }

        await client.addHook(.afterToolExecution) { [weak self] (context: AfterToolExecutionContext) async throws -> Void in
            await self?.handleAfterToolExecution(context)
        }
    }

    private func handleBeforeToolExecution(_ context: BeforeToolExecutionContext) async {
        let toolInput = ToolInput(data: context.input)
        let summary = await client.formatToolCallSummary(toolName: context.toolName, input: toolInput)
        let metadata = await client.getToolMetadata(toolName: context.toolName)

        // Update existing execution or create new one
        if let execution = toolExecutions[context.toolUseId] {
            execution.input = summary
            execution.inputData = context.input
            execution.metadata = metadata
        } else {
            let execution = ToolExecution(
                id: context.toolUseId,
                name: context.toolName,
                input: summary,
                inputData: context.input,
                metadata: metadata
            )
            toolExecutions[context.toolUseId] = execution
        }
    }

    private func handleAfterToolExecution(_ context: AfterToolExecutionContext) async {
        guard let execution = toolExecutions[context.toolUseId] else { return }
        execution.output = context.result.content
        execution.isError = context.result.isError
        execution.isComplete = true
    }

    // MARK: - Messaging

    func sendMessage(text: String) async throws {
        let userMessageID = UUID()
        messages[userMessageID] = ConversationMessage(
            textContent: text,
            id: userMessageID,
            kind: .user
        )

        do {
            for await message in await client.query(text) {
                try Task.checkCancellation()

                if case .assistant(let assistantMsg) = message {
                    var contentBlocks: [MessageContent] = []

                    for block in assistantMsg.content {
                        switch block {
                        case .text(let textBlock):
                            contentBlocks.append(.text(textBlock.text))

                        case .toolUse(let toolBlock):
                            // Create ToolExecution immediately if it doesn't exist
                            // (beforeToolExecution hook will fill in the input summary later)
                            if toolExecutions[toolBlock.id] == nil {
                                toolExecutions[toolBlock.id] = ToolExecution(
                                    id: toolBlock.id,
                                    name: toolBlock.name,
                                    input: "", // Will be filled by hook
                                    inputData: toolBlock.input.toData()
                                )
                            }

                            if let execution = toolExecutions[toolBlock.id] {
                                contentBlocks.append(.toolExecution(execution))
                            }

                        default:
                            break
                        }
                    }

                    // Each message from the stream is complete - just create a new entry
                    let messageID = UUID()
                    messages[messageID] = ConversationMessage(
                        content: contentBlocks,
                        id: messageID,
                        kind: .assistant
                    )
                }
            }

            try? await saveSession()

        } catch {
            // Remove last message if it's an assistant message (was in progress when error occurred)
            if let (lastID, lastMessage) = messages.elements.last,
               lastMessage.kind == .assistant {
                messages.removeValue(forKey: lastID)
            }

            let errorContent: String
            if let claudeError = error as? ClaudeError {
                switch claudeError {
                case .apiError(let message):
                    errorContent = "API Error: \(message)"
                case .maxTurnsReached:
                    errorContent = "Maximum conversation turns reached"
                case .cancelled:
                    errorContent = "Request cancelled"
                default:
                    errorContent = "\(claudeError)"
                }
            } else if error is CancellationError {
                errorContent = "Request cancelled"
            } else {
                errorContent = "\(error)"
            }

            let errorMessageID = UUID()
            messages[errorMessageID] = ConversationMessage(
                textContent: errorContent,
                id: errorMessageID,
                kind: .error
            )
        }
    }

    // MARK: - Persistence

    private var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private var conversationDirectory: URL {
        documentsDirectory.appendingPathComponent("conversations/\(id.uuidString)")
    }

    private var sessionFileURL: URL {
        conversationDirectory.appendingPathComponent("session.json")
    }

    private var toolOutputsFileURL: URL {
        conversationDirectory.appendingPathComponent("tool_outputs.json")
    }

    var lastMessageTimestamp: Date {
        messages.values.last?.timestamp ?? Date()
    }

    private func saveToolOutputs() throws {
        var manifest = ToolOutputsManifest(executions: [:])

        for (id, execution) in toolExecutions {
            manifest.executions[id] = PersistedToolExecution(
                id: execution.id,
                name: execution.name,
                input: execution.input,
                inputData: execution.inputData,
                output: execution.output,
                isError: execution.isError
            )
        }

        try saveJSON(manifest, to: toolOutputsFileURL)
    }

    private func loadToolOutputs() throws {
        guard FileManager.default.fileExists(atPath: toolOutputsFileURL.path) else {
            return
        }

        let manifest: ToolOutputsManifest = try loadJSON(from: toolOutputsFileURL)

        for (id, persisted) in manifest.executions {
            let execution = ToolExecution(
                id: persisted.id,
                name: persisted.name,
                input: persisted.input,
                inputData: persisted.inputData
            )
            execution.output = persisted.output
            execution.isError = persisted.isError
            execution.isComplete = true
            toolExecutions[id] = execution
        }
    }

    func saveSession() async throws {
        try FileManager.default.createDirectory(
            at: conversationDirectory,
            withIntermediateDirectories: true
        )

        let data = try await client.exportSession()
        try data.write(to: sessionFileURL)

        // Save tool outputs
        try saveToolOutputs()

        try await updateConversationsManifest()
    }

    private func updateConversationsManifest() async throws {
        let manifestURL = documentsDirectory.appendingPathComponent("conversations/conversations.json")

        var manifest: ConversationsManifest
        if FileManager.default.fileExists(atPath: manifestURL.path),
           let existing = try? loadJSON(from: manifestURL) as ConversationsManifest {
            manifest = existing
        } else {
            manifest = ConversationsManifest(conversations: [])
        }

        if let index = manifest.conversations.firstIndex(where: { $0.id == id }) {
            manifest.conversations[index].lastMessageTimestamp = lastMessageTimestamp
        } else {
            manifest.conversations.append(ConversationMetadata(
                id: id,
                lastMessageTimestamp: lastMessageTimestamp
            ))
        }

        manifest.conversations.sort { $0.lastMessageTimestamp > $1.lastMessageTimestamp }

        try FileManager.default.createDirectory(
            at: manifestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try saveJSON(manifest, to: manifestURL)
    }

    func rebuildMessagesFromHistory() async {
        let history = await client.history
        messages.removeAll()

        // Load persisted tool outputs first
        try? loadToolOutputs()

        for message in history {
            switch message {
            case .user(let userMsg):
                let messageID = UUID()
                messages[messageID] = ConversationMessage(
                    textContent: userMsg.content,
                    id: messageID,
                    kind: .user
                )

            case .assistant(let assistantMsg):
                var contentBlocks: [MessageContent] = []

                for block in assistantMsg.content {
                    switch block {
                    case .text(let textBlock):
                        contentBlocks.append(.text(textBlock.text))

                    case .toolUse(let toolBlock):
                        // Use loaded tool execution if available, otherwise create a new one
                        let execution = toolExecutions[toolBlock.id] ?? {
                            let newExecution = ToolExecution(
                                id: toolBlock.id,
                                name: toolBlock.name,
                                input: "", // Will be empty if not persisted
                                inputData: toolBlock.input.toData()
                            )
                            newExecution.isComplete = true
                            toolExecutions[toolBlock.id] = newExecution
                            return newExecution
                        }()
                        contentBlocks.append(.toolExecution(execution))

                    default:
                        break
                    }
                }

                let messageID = UUID()
                messages[messageID] = ConversationMessage(
                    content: contentBlocks,
                    id: messageID,
                    kind: .assistant
                )

            default:
                break
            }
        }
    }
}
