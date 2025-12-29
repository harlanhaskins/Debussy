//
//  UserLocationTool.swift
//
//
//  Created by Harlan Haskins on 12/29/25.
//

import Foundation
import CoreLocation
import SwiftClaude

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Tool Definition

public struct UserLocationTool: Tool {
    public typealias Input = UserLocationToolInput

    private let locationController: LocationController

    public var description: String {
        "Get the user's current location as coordinates or address"
    }

    public var inputSchema: JSONSchema {
        Input.schema
    }

    public init(locationController: LocationController) {
        self.locationController = locationController
    }

    public func execute(input: UserLocationToolInput) async throws -> ToolResult {
        // Check permission
        if let errorMessage = await locationController.checkPermission() {
            return ToolResult(content: errorMessage, isError: true)
        }

        // Get current location
        do {
            let location = try await locationController.currentLocation()

            switch input.format {
            case .coordinates:
                let result = """
                Latitude: \(location.coordinate.latitude)
                Longitude: \(location.coordinate.longitude)
                Accuracy: ±\(location.horizontalAccuracy)m
                """
                return ToolResult(content: result)

            case .address:
                let address = try await locationController.address(for: location)
                return ToolResult(content: address)
            }
        } catch {
            return ToolResult(
                content: "Failed to get location: \(error.localizedDescription)",
                isError: true
            )
        }
    }

    public func formatCallSummary(input: UserLocationToolInput) -> String {
        switch input.format {
        case .coordinates:
            return "get coordinates"
        case .address:
            return "get address"
        }
    }
}

// MARK: - Input

public struct UserLocationToolInput: ToolInput {
    public enum Format: String, Codable, Sendable {
        case coordinates
        case address
    }

    public let format: Format

    public init(format: Format) {
        self.format = format
    }

    public static var schema: JSONSchema {
        .object(
            properties: [
                "format": .string(description: "Format for location data: 'coordinates' for lat/long, 'address' for human-readable address")
            ],
            required: ["format"]
        )
    }
}

// MARK: - Permission Hook

/// Setup hook to request location permissions before tool execution
public func setupLocationPermissionHook(client: ClaudeClient, locationController: LocationController) async {
    await client.addHook(.beforeToolExecution) { (context: BeforeToolExecutionContext) async in
        guard context.toolName == UserLocationTool.name else { return }

        // No need to check input - UserLocationTool always needs location permission
        await MainActor.run {
            locationController.requestPermission()
        }
    }
}
