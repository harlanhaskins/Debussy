//
//  Persistence.swift
//
//
//  Created by Harlan Haskins on 12/28/25.
//

import Foundation
import System

// MARK: - Persistence Models

struct ConversationMetadata: Codable, Identifiable {
    let id: UUID
    var lastMessageTimestamp: Date
}

struct ConversationsManifest: Codable {
    var conversations: [ConversationMetadata]
}

// MARK: - Tool Output Persistence

struct PersistedToolExecution: Codable {
    let id: String
    let name: String
    let input: String
    let inputData: Data?  // For reconstruction on load
    let output: String
    let outputData: Data? // For reconstruction on load
    let isError: Bool
}

struct ToolOutputsManifest: Codable {
    var executions: [String: PersistedToolExecution] // Keyed by tool use ID
}

// MARK: - File Attachment Persistence

struct PersistedFileAttachment: Codable {
    let id: UUID
    let relativePath: String
    let fileName: String
    let mimeType: String
    let fileSize: Int

    init(from attachment: FileAttachment, conversationDirectory: FilePath) {
        self.id = attachment.id
        // Store path relative to conversation directory
        let conversationComponents = conversationDirectory.components
        let attachmentComponents = attachment.path.components

        if attachmentComponents.starts(with: conversationComponents) {
            let relativeComponents = attachmentComponents.dropFirst(conversationComponents.count)
            let relativePath = FilePath(root: nil, relativeComponents)
            self.relativePath = relativePath.string
        } else {
            self.relativePath = attachment.path.lastComponent?.string ?? ""
        }
        self.fileName = attachment.fileName
        self.mimeType = attachment.mimeType
        self.fileSize = attachment.fileSize
    }

    func toFileAttachment(conversationDirectory: FilePath) -> FileAttachment {
        FileAttachment(
            id: id,
            path: conversationDirectory.appending(relativePath),
            fileName: fileName,
            mimeType: mimeType,
            fileSize: fileSize
        )
    }
}

struct PersistedThinking: Codable {
    let thinking: String
    let signature: String?
}

enum PersistedMessageContent: Codable {
    case text(String)
    case thinking(PersistedThinking)
    case toolExecution(String) // Tool execution ID
    case fileAttachment(PersistedFileAttachment)

    enum CodingKeys: String, CodingKey {
        case type
        case data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "text":
            let text = try container.decode(String.self, forKey: .data)
            self = .text(text)
        case "thinking":
            // Support both old format (String) and new format (PersistedThinking)
            if let thinking = try? container.decode(PersistedThinking.self, forKey: .data) {
                self = .thinking(thinking)
            } else if let thinkingString = try? container.decode(String.self, forKey: .data) {
                self = .thinking(PersistedThinking(thinking: thinkingString, signature: nil))
            } else {
                throw DecodingError.dataCorruptedError(
                    forKey: .data,
                    in: container,
                    debugDescription: "Invalid thinking data"
                )
            }
        case "toolExecution":
            let id = try container.decode(String.self, forKey: .data)
            self = .toolExecution(id)
        case "fileAttachment":
            let attachment = try container.decode(PersistedFileAttachment.self, forKey: .data)
            self = .fileAttachment(attachment)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown content type: \(type)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .data)
        case .thinking(let thinking):
            try container.encode("thinking", forKey: .type)
            try container.encode(thinking, forKey: .data)
        case .toolExecution(let id):
            try container.encode("toolExecution", forKey: .type)
            try container.encode(id, forKey: .data)
        case .fileAttachment(let attachment):
            try container.encode("fileAttachment", forKey: .type)
            try container.encode(attachment, forKey: .data)
        }
    }
}

struct PersistedMessage: Codable {
    let id: UUID
    let content: [PersistedMessageContent]
    let kind: String // "user", "assistant", "error"
    let timestamp: Date
    let resultedInError: Bool
}

struct MessagesManifest: Codable {
    var messages: [PersistedMessage]
}
