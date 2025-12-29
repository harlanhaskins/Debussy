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
    var inputData: Data? // Raw JSON input for the tool
    var output: String = ""
    var isError: Bool = false
    var isComplete: Bool = false
    var metadata: [String: String] = [:] // Additional metadata (e.g., MCP server name)

    init(id: String, name: String, input: String, inputData: Data? = nil, metadata: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.input = input
        self.inputData = inputData
        self.metadata = metadata
    }
}
