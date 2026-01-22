//
//  OpenURLTool.swift
//

import Foundation
import SwiftClaude

// MARK: - Tool Definition

public protocol URLOpener: Sendable {
    func `open`(_ url: URL) async
}

public struct OpenURLTool: Tool {
    public typealias Input = OpenURLToolInput
    public typealias Output = String

    public var description: String {
        """
        Opens a URL on behalf of the user. Does not support file:// URLs, but supports
        other URL schemes for other installed applications.
        
        If the URL scheme is an HTTP URL, will open in an in-app browser window.
        """
    }

    public var inputSchema: JSONSchema {
        Input.schema
    }

    let opener: URLOpener

    public init(opener: URLOpener) {
        self.opener = opener
    }

    public func execute(input: Input) async throws -> ToolResult {
        await Task { @MainActor in
            await opener.open(input.url)
            return .init(content: "Opened URL \(input.url.absoluteString)")
        }.value
    }

    public func formatCallSummary(input: ContactsSearchToolInput) -> String {
        "search contacts with expression '\(input.expression)'"
    }
}

// MARK: - Input

public struct OpenURLToolInput: ToolInput {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static var schema: JSONSchema {
        .object(
            properties: [
                "url": .string(description: "A URL to open on behalf of the user. Must not be a file:// URL.")
            ],
            required: ["url"]
        )
    }
}
