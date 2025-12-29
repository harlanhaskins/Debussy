//
//  Persistence.swift
//
//
//  Created by Harlan Haskins on 12/28/25.
//

import Foundation

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
