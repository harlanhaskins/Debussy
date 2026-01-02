//
//  ConversationMessage.swift
//
//
//  Created by Harlan Haskins on 12/28/25.
//

import Foundation
import System

// MARK: - File Attachment

struct FileAttachment: Identifiable, Equatable {
    let id: UUID
    let path: FilePath
    let fileName: String
    let mimeType: String
    let fileSize: Int
}

// MARK: - Message Content

enum MessageContent: Identifiable {
    case text(String)
    case toolExecution(ToolExecution)
    case fileAttachment(FileAttachment)

    var id: String {
        switch self {
        case .text(let content):
            return "text_\(content.prefix(50).hashValue)"
        case .toolExecution(let execution):
            return "tool_\(execution.id)"
        case .fileAttachment(let attachment):
            return "file_\(attachment.id.uuidString)"
        }
    }
}

struct ConversationMessage: Identifiable {
    enum Kind {
        case user
        case assistant
        case error
    }

    var content: [MessageContent]
    var id: UUID
    var kind: Kind
    var resultedInError: Bool = false
    var timestamp: Date = Date()

    var isSent: Bool {
        kind == .user
    }

    // Convenience initializer for text-only messages
    init(textContent: String, id: UUID, kind: Kind) {
        self.content = [.text(textContent)]
        self.id = id
        self.kind = kind
    }

    init(content: [MessageContent], id: UUID, kind: Kind) {
        self.content = content
        self.id = id
        self.kind = kind
    }
}
