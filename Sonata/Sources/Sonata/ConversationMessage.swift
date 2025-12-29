//
//  ConversationMessage.swift
//
//
//  Created by Harlan Haskins on 12/28/25.
//

import Foundation

// MARK: - Message Content

enum MessageContent: Identifiable {
    case text(String)
    case toolExecution(ToolExecution)

    var id: String {
        switch self {
        case .text(let content):
            return "text_\(content.prefix(50).hashValue)"
        case .toolExecution(let execution):
            return "tool_\(execution.id)"
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
