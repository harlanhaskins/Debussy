//
//  Conversation.swift
//
//
//  Created by Harlan Haskins on 12/28/25.
//

import SwiftClaude
import SwiftUI
import Foundation
import System
import Collections

@MainActor @Observable
final class Conversation: Identifiable {
    let id: UUID
    let client: ClaudeClient
    let conversationDirectory: FilePath
    let fileManager: FileAttachmentManager

    init(client: ClaudeClient, id: UUID = UUID()) async {
        self.client = client
        self.id = id

        // Compute conversation directory
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.conversationDirectory = FilePath(documentsDirectory.path).appending("conversations").appending(id.uuidString)

        // Initialize file manager
        self.fileManager = FileAttachmentManager(conversationDirectory: conversationDirectory)

        await setupHooks()
    }

    var messages = OrderedDictionary<UUID, ConversationMessage>()

    // Track tool executions by ID - public so MessageView can look them up
    var toolExecutions: [String: ToolExecution] = [:]
    private let encoder = JSONEncoder()

    // Session for managing active tool executions
    private let executionSession = ToolExecutionSession()

    // Track files currently being uploaded (by file path)
    var uploadingFiles: Set<String> = []

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
        await client.addHook(.beforeToolExecution) { [weak self] (context: BeforeToolExecutionContext) async in
            await self?.handleBeforeToolExecution(context)
        }

        await client.addHook(.afterToolExecution) { [weak self] (context: AfterToolExecutionContext) async in
            await self?.handleAfterToolExecution(context)
        }

        // Register hook for file upload start
        await client.addHook(.beforeFileUpload) { [weak self] (context: BeforeFileUploadContext) async in
            await self?.handleBeforeFileUpload(context)
        }

        // Register hook for file upload completion
        await client.addHook(.afterFileUpload) { [weak self] (context: AfterFileUploadContext) async in
            await self?.handleAfterFileUpload(context)
        }
    }

    private func handleBeforeToolExecution(_ context: BeforeToolExecutionContext) {
        let summary: String
        if let input = context.input {
            summary = client.formatToolCallSummary(toolName: context.toolName, input: input)
        } else {
            summary = "(no input)"
        }
        let metadata = client.toolMetadata(toolName: context.toolName)

        // Update existing execution or create new one
        if let execution = toolExecutions[context.toolUseId] {
            execution.input = summary
            execution.decodedInput = context.input
            execution.metadata = metadata
        } else {
            let execution = ToolExecution(
                id: context.toolUseId,
                name: context.toolName,
                input: summary,
                decodedInput: context.input,
                decodedOutput: nil,
                metadata: metadata
            )
            toolExecutions[context.toolUseId] = execution
        }

        // For SubAgent: create sub-execution session and register task mappings
        if context.toolName == "SubAgent",
           let input = context.input as? SubAgentToolInput,
           let execution = toolExecutions[context.toolUseId] {
            execution.subExecutionSession = ToolExecutionSession()

            let taskIds = input.tasks.enumerated().map { index, _ in "task-\(index)" }
            executionSession.registerSubAgentExecution(parentId: context.toolUseId, taskIds: taskIds)
        }
    }

    private func handleAfterToolExecution(_ context: AfterToolExecutionContext) async {
        guard let execution = toolExecutions[context.toolUseId] else { return }

        execution.output = context.result.content
        execution.isError = context.result.isError
        execution.isComplete = true

        // Store structured output if present
        if context.result.structuredOutput != nil {
            execution.decodedOutput = context.output
        }

        // For SubAgent: finalize sub-executions from batch result
        if execution.name == "SubAgent", let batchResult = context.output as? SubAgentBatchResult {
            var subExecutions: [ToolExecution] = []

            for result in batchResult.results {
                for toolCall in result.toolCalls {
                    let subExecution = ToolExecution(
                        id: toolCall.id,
                        name: toolCall.toolName,
                        input: toolCall.summary,
                        decodedInput: nil,
                        decodedOutput: nil,
                        metadata: [:]
                    )
                    subExecution.isComplete = true
                    subExecutions.append(subExecution)
                }
            }

            // Replace live executions with final complete list
            execution.subExecutionSession?.replace(with: subExecutions)
        }

        // For SubAgent: clean up task ID mappings
        if context.toolName == "SubAgent" {
            executionSession.cleanupSubAgentExecution(parentId: context.toolUseId)
        }

        try? await saveSession()
    }

    private func handleBeforeFileUpload(_ context: BeforeFileUploadContext) {
        uploadingFiles.insert(context.fileInfo.filePath)
    }

    private func handleAfterFileUpload(_ context: AfterFileUploadContext) {
        uploadingFiles.remove(context.fileInfo.filePath)
    }

    // Handle live sub-tool updates from SubAgent
    func handleSubAgentToolCall(taskId: String, toolName: String, summary: String) {
        guard let parentExecutionId = executionSession.parentExecutionId(forSubAgentTask: taskId),
              let execution = toolExecutions[parentExecutionId],
              let session = execution.subExecutionSession else {
            return
        }

        session.addSubToolExecution(id: UUID().uuidString, name: toolName, input: summary)
    }

    // MARK: - Tool History

    /// Returns tool execution history in chronological order
    func toolExecutionHistory() -> [SwiftClaude.ToolExecutionInfo] {
        // Collect tool executions in order by iterating through messages
        var history: [SwiftClaude.ToolExecutionInfo] = []

        for (_, message) in messages {
            for content in message.content {
                if case .toolExecution(let execution) = content,
                   execution.isComplete {
                    // Use decodedOutput if available (structured outputs), otherwise fall back to string output
                    let output: (any ToolOutput)? = execution.decodedOutput ?? execution.output

                    let info = SwiftClaude.ToolExecutionInfo(
                        id: execution.id,
                        name: execution.name,
                        summary: execution.input,
                        input: execution.decodedInput,
                        output: output
                    )
                    history.append(info)
                }
            }
        }

        return history
    }

    // MARK: - Messaging

    func sendMessage(text: String, attachments: [FileAttachment] = []) async throws {
        let userMessageID = UUID()

        // Build Sonata message content (for display)
        var displayContent: [MessageContent] = [.text(text)]
        displayContent.append(contentsOf: attachments.map { .fileAttachment($0) })

        messages[userMessageID] = ConversationMessage(
            content: displayContent,
            id: userMessageID,
            kind: .user
        )

        // Build SwiftClaude content blocks (for API)
        let claudeMessage: UserMessage
        if attachments.isEmpty {
            // Simple text message
            claudeMessage = UserMessage(content: text)
        } else {
            // Multimodal message with text and attachments
            var contentBlocks: [ContentBlock] = [.text(SwiftClaude.TextBlock(text: text))]

            // Load files and create content blocks
            for attachment in attachments {
                do {
                    let contentBlock = try fileManager.createContentBlock(for: attachment)
                    contentBlocks.append(contentBlock)
                } catch {
                    print("Error loading attachment \(attachment.fileName): \(error)")
                    // Continue with other attachments
                }
            }

            claudeMessage = SwiftClaude.UserMessage(content: .blocks(contentBlocks))
        }

        do {
            for await message in await client.query(claudeMessage) {
                try Task.checkCancellation()

                if case .assistant(let assistantMsg) = message {
                    var contentBlocks: [MessageContent] = []

                    for block in assistantMsg.content {
                        switch block {
                        case .text(let textBlock):
                            contentBlocks.append(.text(textBlock.text))

                        case .thinking(let thinkingBlock):
                            contentBlocks.append(.thinking(ThinkingContent(thinking: thinkingBlock.thinking, signature: thinkingBlock.signature)))

                        case .toolUse(let toolBlock):
                            // Create ToolExecution immediately if it doesn't exist
                            // (beforeToolExecution hook will fill in the input summary later)
                            if toolExecutions[toolBlock.id] == nil {
                                toolExecutions[toolBlock.id] = ToolExecution(
                                    id: toolBlock.id,
                                    name: toolBlock.name,
                                    input: "", // Will be filled by hook
                                    decodedInput: client.decodeToolInput(toolName: toolBlock.name, inputData: toolBlock.input.data),
                                    decodedOutput: nil,
                                    metadata: [:]
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

    private var sessionFilePath: FilePath {
        conversationDirectory.appending("session.json")
    }

    private var toolOutputsFilePath: FilePath {
        conversationDirectory.appending("tool_outputs.json")
    }

    private var messagesFilePath: FilePath {
        conversationDirectory.appending("messages.json")
    }

    var lastMessageTimestamp: Date {
        messages.values.last?.timestamp ?? Date()
    }

    private func saveToolOutputs() throws {
        var manifest = ToolOutputsManifest(executions: [:])

        for (id, execution) in toolExecutions {
            // Encode decoded input/output to Data for persistence
            let inputData = execution.decodedInput.flatMap { input in
                try? encoder.encode(input)
            }
            let outputData = execution.decodedOutput.flatMap { output in
                try? encoder.encode(output)
            }

            manifest.executions[id] = PersistedToolExecution(
                id: execution.id,
                name: execution.name,
                input: execution.input,
                inputData: inputData,
                output: execution.output,
                outputData: outputData,
                isError: execution.isError
            )
        }

        try saveJSON(manifest, to: toolOutputsFilePath)
    }

    private func loadToolOutputs() throws {
        guard FileManager.default.fileExists(atPath: toolOutputsFilePath.string) else {
            return
        }

        let manifest: ToolOutputsManifest = try loadJSON(from: toolOutputsFilePath)

        for (id, persisted) in manifest.executions {
            // Decode input/output from persisted data
            let decodedInput = persisted.inputData.flatMap {
                client.decodeToolInput(toolName: persisted.name, inputData: $0)
            }
            let decodedOutput = persisted.outputData.flatMap {
                client.decodeToolOutput(toolName: persisted.name, outputData: $0)
            }

            let execution = ToolExecution(
                id: persisted.id,
                name: persisted.name,
                input: persisted.input,
                decodedInput: decodedInput,
                decodedOutput: decodedOutput,
                metadata: [:]
            )
            execution.output = persisted.output
            execution.isError = persisted.isError
            execution.isComplete = true

            // For SubAgent: extract tool calls and populate subToolExecutions
            if persisted.name == "SubAgent", let batchResult = decodedOutput as? SubAgentBatchResult {
                let session = ToolExecutionSession()
                var subExecutions: [ToolExecution] = []

                for result in batchResult.results {
                    for toolCall in result.toolCalls {
                        let subExecution = ToolExecution(
                            id: toolCall.id,
                            name: toolCall.toolName,
                            input: toolCall.summary,
                            decodedInput: nil,
                            decodedOutput: nil,
                            metadata: [:]
                        )
                        subExecution.isComplete = true
                        subExecutions.append(subExecution)
                    }
                }

                session.replace(with: subExecutions)
                execution.subExecutionSession = session
            }

            toolExecutions[id] = execution
        }
    }

    private func saveMessages() throws {
        var persistedMessages: [PersistedMessage] = []

        for (_, message) in messages {
            var persistedContent: [PersistedMessageContent] = []

            for content in message.content {
                switch content {
                case .text(let text):
                    persistedContent.append(.text(text))

                case .thinking(let thinking):
                    persistedContent.append(.thinking(PersistedThinking(thinking: thinking.thinking, signature: thinking.signature)))

                case .toolExecution(let execution):
                    persistedContent.append(.toolExecution(execution.id))

                case .fileAttachment(let attachment):
                    persistedContent.append(.fileAttachment(PersistedFileAttachment(from: attachment, conversationDirectory: conversationDirectory)))
                }
            }

            let kindString: String
            switch message.kind {
            case .user: kindString = "user"
            case .assistant: kindString = "assistant"
            case .error: kindString = "error"
            }

            persistedMessages.append(PersistedMessage(
                id: message.id,
                content: persistedContent,
                kind: kindString,
                timestamp: message.timestamp,
                resultedInError: message.resultedInError
            ))
        }

        let manifest = MessagesManifest(messages: persistedMessages)
        try saveJSON(manifest, to: messagesFilePath)
    }

    private func loadMessages() throws {
        guard FileManager.default.fileExists(atPath: messagesFilePath.string) else {
            return
        }

        let manifest: MessagesManifest = try loadJSON(from: messagesFilePath)

        messages.removeAll()

        for persisted in manifest.messages {
            var messageContent: [MessageContent] = []

            for content in persisted.content {
                switch content {
                case .text(let text):
                    messageContent.append(.text(text))

                case .thinking(let thinking):
                    messageContent.append(.thinking(ThinkingContent(thinking: thinking.thinking, signature: thinking.signature)))

                case .toolExecution(let executionId):
                    if let execution = toolExecutions[executionId] {
                        messageContent.append(.toolExecution(execution))
                    }

                case .fileAttachment(let persistedAttachment):
                    messageContent.append(.fileAttachment(persistedAttachment.toFileAttachment(conversationDirectory: conversationDirectory)))
                }
            }

            let kind: ConversationMessage.Kind
            switch persisted.kind {
            case "user": kind = .user
            case "assistant": kind = .assistant
            case "error": kind = .error
            default: kind = .user
            }

            var message = ConversationMessage(
                content: messageContent,
                id: persisted.id,
                kind: kind
            )
            message.timestamp = persisted.timestamp
            message.resultedInError = persisted.resultedInError

            messages[persisted.id] = message
        }
    }

    func saveSession() async throws {
        try FileManager.default.createDirectory(
            at: URL(filePath: conversationDirectory)!,
            withIntermediateDirectories: true
        )

        let data = try await client.exportSession()
        try data.write(to: URL(filePath: sessionFilePath)!)

        // Save tool outputs
        try saveToolOutputs()

        // Save messages
        try saveMessages()

        try await updateConversationsManifest()
    }

    private func updateConversationsManifest() async throws {
        let manifestPath = conversationDirectory.removingLastComponent().appending("conversations.json")
        let manifestURL = URL(filePath: manifestPath)!

        var manifest: ConversationsManifest
        if FileManager.default.fileExists(atPath: manifestPath.string),
           let existing = try? loadJSON(from: manifestPath) as ConversationsManifest {
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
        try saveJSON(manifest, to: manifestPath)
    }

    func rebuildMessagesFromHistory() async {
        // Try to load persisted messages first
        try? loadToolOutputs()

        if (try? loadMessages()) != nil {
            // Successfully loaded messages from file
            return
        }

        // Fall back to rebuilding from SwiftClaude history
        let history = await client.history
        messages.removeAll()

        for message in history {
            switch message {
            case .user(let userMsg):
                let messageID = UUID()
                var displayContent: [MessageContent] = []

                switch userMsg.content {
                case .text(let text):
                    displayContent = [.text(text)]

                case .blocks(let blocks):
                    for block in blocks {
                        switch block {
                        case .text(let textBlock):
                            displayContent.append(.text(textBlock.text))

                        case .image, .document:
                            // Note: We don't have the FileAttachment metadata here
                            // since it's stored in the attachments directory
                            // For now, just skip displaying file attachments on reload
                            // TODO: Persist FileAttachment metadata separately
                            break

                        default:
                            break
                        }
                    }
                }

                messages[messageID] = ConversationMessage(
                    content: displayContent,
                    id: messageID,
                    kind: .user
                )

            case .assistant(let assistantMsg):
                var contentBlocks: [MessageContent] = []

                for block in assistantMsg.content {
                    switch block {
                    case .text(let textBlock):
                        contentBlocks.append(.text(textBlock.text))

                    case .thinking(let thinkingBlock):
                        contentBlocks.append(.thinking(ThinkingContent(thinking: thinkingBlock.thinking, signature: thinkingBlock.signature)))

                    case .toolUse(let toolBlock):
                        // Use loaded tool execution if available, otherwise create a new one
                        let execution = toolExecutions[toolBlock.id] ?? {
                            let newExecution = ToolExecution(
                                id: toolBlock.id,
                                name: toolBlock.name,
                                input: "", // Will be empty if not persisted
                                decodedInput: client.decodeToolInput(toolName: toolBlock.name, inputData: toolBlock.input.data),
                                decodedOutput: nil,
                                metadata: [:]
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
