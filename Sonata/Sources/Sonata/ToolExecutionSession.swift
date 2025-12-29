//
//  ToolExecutionSession.swift
//
//
//  Created by Harlan Haskins on 12/29/25.
//

import Foundation
import SwiftUI

/// Manages the state of tool executions (can be used for top-level or nested sub-executions)
@MainActor @Observable
class ToolExecutionSession {
    // Tool executions managed by this session
    private(set) var executions: [ToolExecution] = []

    // For SubAgent: map task IDs to parent execution IDs
    private var subAgentTaskToParent: [String: String] = [:]
    private var subAgentParentToTasks: [String: [String]] = [:]

    /// Add a new tool execution to this session
    func add(execution: ToolExecution) {
        executions.append(execution)
    }

    /// Add a sub-tool execution by creating a ToolExecution
    func addSubToolExecution(id: String, name: String, input: String, isComplete: Bool = false) {
        let execution = ToolExecution(
            id: id,
            name: name,
            input: input,
            decodedInput: nil,
            decodedOutput: nil,
            metadata: [:]
        )
        execution.isComplete = isComplete
        executions.append(execution)
    }

    /// Replace all executions with a new list
    func replace(with executions: [ToolExecution]) {
        self.executions = executions
    }

    /// Register a SubAgent execution with its task IDs
    func registerSubAgentExecution(parentId: String, taskIds: [String]) {
        subAgentParentToTasks[parentId] = taskIds
        for taskId in taskIds {
            subAgentTaskToParent[taskId] = parentId
        }
    }

    /// Get the parent execution ID for a SubAgent task ID
    func parentExecutionId(forSubAgentTask taskId: String) -> String? {
        subAgentTaskToParent[taskId]
    }

    /// Clean up mappings for a completed SubAgent execution
    func cleanupSubAgentExecution(parentId: String) {
        if let taskIds = subAgentParentToTasks[parentId] {
            for taskId in taskIds {
                subAgentTaskToParent.removeValue(forKey: taskId)
            }
            subAgentParentToTasks.removeValue(forKey: parentId)
        }
    }
}
