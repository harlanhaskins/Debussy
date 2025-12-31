//
//  ContactsSearchTool.swift
//
//
//  Created by Claude on 12/30/25.
//

import Foundation
import Contacts
import SwiftClaude

// MARK: - Tool Definition

public struct ContactsSearchTool: Tool {
    public typealias Input = ContactsSearchToolInput
    public typealias Output = ContactsSearchToolOutput

    private let contactsController: ContactsController

    public var description: String {
        "Search the user's contacts by name, email, phone number, or address. Returns contact information including phone numbers, email addresses, and postal addresses. Area codes in phone numbers can be used to perform location-specific queries when postal addresses are not available."
    }

    public var inputSchema: JSONSchema {
        Input.schema
    }

    public init(contactsController: ContactsController) {
        self.contactsController = contactsController
    }

    public func execute(input: ContactsSearchToolInput) async throws -> ToolResult {
        // Validate input
        let trimmedQuery = input.query.trimmingCharacters(in: .whitespaces)
        guard !trimmedQuery.isEmpty else {
            return ToolResult(content: "Search query cannot be empty", isError: true)
        }

        // Check permission
        if let errorMessage = await contactsController.checkPermission() {
            return ToolResult(content: errorMessage, isError: true)
        }

        // Perform search
        do {
            let results = try await contactsController.searchContacts(
                query: trimmedQuery,
                limit: input.resultLimit
            )

            if results.isEmpty {
                return ToolResult(content: "No contacts found matching '\(trimmedQuery)'")
            }

            // Format text output
            var output = "Found \(results.count) contact(s) matching '\(trimmedQuery)':\n\n"

            for (index, result) in results.enumerated() {
                output += "\(index + 1). \(result.displayName)\n"

                // Phone numbers
                if !result.phoneNumbers.isEmpty {
                    for phone in result.phoneNumbers {
                        let label = phone.label.map { " (\($0))" } ?? ""
                        output += "   Phone: \(phone.number)\(label)\n"
                    }
                }

                // Email addresses
                if !result.emailAddresses.isEmpty {
                    for email in result.emailAddresses {
                        output += "   Email: \(email)\n"
                    }
                }

                // Postal addresses
                if !result.postalAddresses.isEmpty {
                    for address in result.postalAddresses {
                        let label = address.label.map { " (\($0))" } ?? ""
                        output += "   Address\(label): \(address.formattedAddress)\n"
                    }
                }

                output += "\n"
            }

            // Create structured output
            let structuredOutput = ContactsSearchToolOutput(results: results)

            return ToolResult(content: output, structuredOutput: structuredOutput)
        } catch {
            return ToolResult(
                content: "Failed to search contacts: \(error.localizedDescription)",
                isError: true
            )
        }
    }

    public func formatCallSummary(input: ContactsSearchToolInput) -> String {
        "search contacts for '\(input.query)'"
    }
}

// MARK: - Input

public struct ContactsSearchToolInput: ToolInput {
    public let query: String
    public let resultLimit: Int

    public init(query: String, resultLimit: Int = 10) {
        self.query = query
        self.resultLimit = min(resultLimit, 50)  // Cap at 50
    }

    public static var schema: JSONSchema {
        .object(
            properties: [
                "query": .string(description: "Search query (searches across name, email, phone number, and addresses)"),
                "resultLimit": .integer(description: "Maximum number of results to return (default: 10, max: 50)")
            ],
            required: ["query"]
        )
    }
}

// MARK: - Output

public struct ContactsSearchToolOutput: Codable, Sendable {
    public let results: [ContactResult]

    public init(results: [ContactResult]) {
        self.results = results
    }
}

// MARK: - Permission Hook

/// Setup hook to request contacts permissions before tool execution
public func setupContactsPermissionHook(client: ClaudeClient, contactsController: ContactsController) async {
    await client.addHook(.beforeToolExecution) { (context: BeforeToolExecutionContext) async in
        guard context.toolName == ContactsSearchTool.name else { return }

        await contactsController.requestPermission()
    }
}
