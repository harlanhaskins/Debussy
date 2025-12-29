//
//  ToolExecution.swift
//
//
//  Created by Harlan Haskins on 12/28/25.
//

import SwiftUI
import SwiftClaude

// MARK: - Tool Execution

@MainActor @Observable
class ToolExecution: Identifiable {
    let id: String
    let name: String
    var input: String
    var decodedInput: (any ToolInput)? // Decoded tool input (type-erased)
    var output: String = ""
    var decodedOutput: (any ToolOutput)? // Decoded tool output (type-erased)
    var isError: Bool = false
    var isComplete: Bool = false
    var metadata: [String: String] = [:] // Additional metadata (e.g., MCP server name)

    init(
        id: String,
        name: String,
        input: String,
        decodedInput: (any ToolInput)?,
        decodedOutput: (any ToolOutput)?,
        metadata: [String: String]
    ) {
        self.id = id
        self.name = name
        self.input = input
        self.decodedInput = decodedInput
        self.decodedOutput = decodedOutput
        self.metadata = metadata
    }
}
