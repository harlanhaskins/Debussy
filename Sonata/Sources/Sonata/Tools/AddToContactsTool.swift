//
//  AddToContactsTool.swift
//
//
//  Created by Claude on 12/31/25.
//

import Foundation
@preconcurrency import Contacts
import SwiftClaude

// MARK: - Tool Definition

public struct AddToContactsTool: Tool {
    public typealias Input = AddToContactsToolInput
    public typealias Output = AddToContactsToolOutput

    private let contactsController: ContactsController

    public var description: String {
        "Add a new contact to the user's contacts. Saves contact information including name, phone numbers, email addresses, and organization. Requires at least a name (first or last) and at least one phone number or email address."
    }

    public var inputSchema: JSONSchema {
        Input.schema
    }

    public init(contactsController: ContactsController) {
        self.contactsController = contactsController
    }

    public func execute(input: AddToContactsToolInput) async throws -> ToolResult {
        // Validate name is provided
        if input.givenName == nil && input.familyName == nil {
            return ToolResult(
                content: "Please provide at least a first name or last name for the contact",
                isError: true
            )
        }

        // Validate at least phone number or email is provided
        if input.phoneNumbers?.isEmpty != false && input.emailAddresses?.isEmpty != false {
            return ToolResult(
                content: "Please provide at least a phone number or email address for the contact",
                isError: true
            )
        }

        // Check permission
        if let errorMessage = await contactsController.checkPermission() {
            return ToolResult(content: errorMessage, isError: true)
        }

        // Add contact
        do {
            let phoneNumbers = input.phoneNumbers?.map { ($0.label, $0.number) }

            let contactId = try await contactsController.addContact(
                givenName: input.givenName,
                familyName: input.familyName,
                phoneNumbers: phoneNumbers,
                emailAddresses: input.emailAddresses,
                organization: input.organization
            )

            // Format output
            let name = [input.givenName, input.familyName].compactMap { $0 }.joined(separator: " ")
            let displayName = !name.isEmpty ? name : "New Contact"

            var output = "Successfully added contact: \(displayName)\n"

            if let phones = input.phoneNumbers, !phones.isEmpty {
                output += "\nPhone numbers:\n"
                for phone in phones {
                    let label = phone.label.map { " (\($0))" } ?? ""
                    output += "  \(phone.number)\(label)\n"
                }
            }

            if let emails = input.emailAddresses, !emails.isEmpty {
                output += "\nEmail addresses:\n"
                for email in emails {
                    output += "  \(email)\n"
                }
            }

            if let org = input.organization {
                output += "\nOrganization: \(org)\n"
            }

            let structuredOutput = AddToContactsToolOutput(contactId: contactId)
            return ToolResult(content: output, structuredOutput: structuredOutput)
        } catch {
            return ToolResult(
                content: "Failed to add contact: \(error.localizedDescription)",
                isError: true
            )
        }
    }

    public func formatCallSummary(input: AddToContactsToolInput) -> String {
        let name = [input.givenName, input.familyName].compactMap { $0 }.joined(separator: " ")
        return "add contact '\(name.isEmpty ? "new contact" : name)'"
    }
}

// MARK: - Input

public struct AddToContactsToolInput: ToolInput {
    public let givenName: String?
    public let familyName: String?
    public let phoneNumbers: [PhoneNumberInput]?
    public let emailAddresses: [String]?
    public let organization: String?

    public init(
        givenName: String? = nil,
        familyName: String? = nil,
        phoneNumbers: [PhoneNumberInput]? = nil,
        emailAddresses: [String]? = nil,
        organization: String? = nil
    ) {
        self.givenName = givenName
        self.familyName = familyName
        self.phoneNumbers = phoneNumbers
        self.emailAddresses = emailAddresses
        self.organization = organization
    }

    public static var schema: JSONSchema {
        .object(
            properties: [
                "givenName": .string(description: "First name of the contact"),
                "familyName": .string(description: "Last name of the contact"),
                "phoneNumbers": .array(
                    items: .object(
                        properties: [
                            "label": .string(description: "Label for the phone number (e.g., 'home', 'work', 'mobile')"),
                            "number": .string(description: "Phone number")
                        ],
                        required: [],
                        description: "Phone number entry"
                    ),
                    description: "Phone numbers to add"
                ),
                "emailAddresses": .array(
                    items: .string(description: "Email address"),
                    description: "Email addresses to add"
                ),
                "organization": .string(description: "Company or organization name")
            ],
            required: []
        )
    }
}

public struct PhoneNumberInput: Codable, Sendable {
    public let label: String?
    public let number: String

    public init(label: String?, number: String) {
        self.label = label
        self.number = number
    }
}

// MARK: - Output

public struct AddToContactsToolOutput: Codable, Sendable {
    public let contactId: String

    public init(contactId: String) {
        self.contactId = contactId
    }
}

// MARK: - Permission Hook

/// Setup hook to request contacts permissions before tool execution
public func setupAddToContactsPermissionHook(client: ClaudeClient, contactsController: ContactsController) async {
    await client.addHook(.beforeToolExecution) { (context: BeforeToolExecutionContext) async in
        guard context.toolName == AddToContactsTool.name else { return }

        await contactsController.requestPermission()
    }
}
