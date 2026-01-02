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
        """
        Search contacts using CEL (Common Expression Language) expressions. Write queries that filter contacts based on their fields.

        AVAILABLE FIELDS:
        - displayName: string (full name, e.g., "John Smith")
        - givenName: string or null (first name)
        - familyName: string or null (last name)
        - phoneNumbers: list of {number: string, label?: string}
        - emailAddresses: list of strings
        - postalAddresses: list of {street?, city?, state?, postalCode?, country?, formattedAddress: string, label?: string}

        OPERATORS:
        - Comparison: ==, !=, <, <=, >, >=
        - Logical: && (and), || (or), ! (not)
        - Membership: in (check if value is in list)
        - Ternary: condition ? trueValue : falseValue

        LIST MACROS (essential for filtering lists):
        - exists(var, predicate): true if ANY element matches
        - all(var, predicate): true if ALL elements match
        - filter(var, predicate): returns list of matching elements
        - exists_one(var, predicate): true if EXACTLY ONE element matches

        QUERY EXAMPLES:

        Basic filtering:
        - displayName == "John Smith" → exact name match
        - familyName == "Smith" → all Smiths
        - givenName != null && familyName != null → contacts with both names

        List membership:
        - "john@example.com" in emailAddresses → has specific email
        - phoneNumbers != [] → has at least one phone number
        - emailAddresses == [] → contacts without email

        Filtering nested lists (IMPORTANT - use exists/all):
        - emailAddresses.exists(e, e == "john@gmail.com") → has Gmail
        - postalAddresses.exists(a, a.city == "San Francisco") → lives in SF
        - postalAddresses.exists(a, a.state == "CA") → California residents
        - phoneNumbers.exists(p, p.number == "415") → 415 area code
        - phoneNumbers.all(p, p.label == "mobile") → all phones are mobile

        Complex queries:
        - familyName == "Smith" && emailAddresses.exists(e, e == "@gmail.com") → Smiths with Gmail
        - postalAddresses.exists(a, a.state == "CA") && phoneNumbers != [] → CA contacts with phone
        - (givenName == "John" || givenName == "Jane") && familyName == "Doe" → John or Jane Doe
        - emailAddresses != [] && phoneNumbers != [] && postalAddresses != [] → complete contact info

        TIPS:
        - Use exists() to check if ANY item in a list matches a condition
        - Use all() to check if EVERY item in a list matches a condition
        - Use filter() to get a subset of a list, then check its length
        - Combine conditions with && (and) and || (or)
        - Use != [] to check if a list is not empty
        - Access nested fields with dot notation: postalAddresses.exists(a, a.city == "Boston")
        """
    }

    public var inputSchema: JSONSchema {
        Input.schema
    }

    public init(contactsController: ContactsController) {
        self.contactsController = contactsController
    }

    public func execute(input: ContactsSearchToolInput) async throws -> ToolResult {
        // Validate input
        let trimmedExpression = input.expression.trimmingCharacters(in: .whitespaces)
        guard !trimmedExpression.isEmpty else {
            return ToolResult(content: "Expression cannot be empty", isError: true)
        }

        // Check permission
        if let errorMessage = await contactsController.checkPermission() {
            return ToolResult(content: errorMessage, isError: true)
        }

        // Filter contacts using CEL expression
        do {
            let results = try await contactsController.filterContacts(
                expression: trimmedExpression,
                limit: input.resultLimit ?? 10
            )

            if results.isEmpty {
                return ToolResult(content: "No contacts found matching expression: '\(trimmedExpression)'")
            }

            // Format text output
            var output = "Found \(results.count) contact(s) matching expression '\(trimmedExpression)':\n\n"

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
                content: "Failed to filter contacts: \(error.localizedDescription)",
                isError: true
            )
        }
    }

    public func formatCallSummary(input: ContactsSearchToolInput) -> String {
        "search contacts with expression '\(input.expression)'"
    }
}

// MARK: - Input

public struct ContactsSearchToolInput: ToolInput {
    public let expression: String
    public let resultLimit: Int?

    public init(expression: String, resultLimit: Int = 10) {
        self.expression = expression
        self.resultLimit = min(resultLimit, 100)  // Cap at 100
    }

    public static var schema: JSONSchema {
        .object(
            properties: [
                "expression": .string(description: "CEL expression to filter contacts. See tool description for complete syntax, operators, and examples. Use exists() macro for list filtering."),
                "resultLimit": .integer(description: "Maximum number of results to return (default: 10, max: 100)")
            ],
            required: ["expression"]
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
