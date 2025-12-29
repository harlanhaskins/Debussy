//
//  MapSearchTool.swift
//
//
//  Created by Harlan Haskins on 12/29/25.
//

import Foundation
import CoreLocation
@preconcurrency import MapKit
import SwiftClaude

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Tool Definition

public struct MapSearchTool: Tool {
    public typealias Input = MapSearchToolInput
    public typealias Output = MapSearchToolOutput

    private let locationController: LocationController

    public var description: String {
        "Search for places near an address or the user's current location"
    }

    public var inputSchema: JSONSchema {
        Input.schema
    }

    public init(locationController: LocationController) {
        self.locationController = locationController
    }

    public func execute(input: MapSearchToolInput) async throws -> ToolResult {
        // Determine the search location
        let searchLocation: CLLocation

        if let address = input.location {
            // Geocode the provided address
            searchLocation = try await geocode(address: address)
        } else {
            // Check permission for current location
            if let errorMessage = await locationController.checkPermission() {
                return ToolResult(content: errorMessage, isError: true)
            }

            // Use current location
            do {
                searchLocation = try await locationController.currentLocation()
            } catch {
                return ToolResult(
                    content: "Failed to get current location: \(error.localizedDescription)",
                    isError: true
                )
            }
        }

        // Perform search
        do {
            let results = try await search(query: input.query, near: searchLocation, resultLimit: input.resultLimit)

            if results.isEmpty {
                return ToolResult(content: "No results found for '\(input.query)'")
            }

            // Format text output
            var output = "Found \(results.count) result(s) for '\(input.query)':\n\n"

            for (index, result) in results.enumerated() {
                output += "\(index + 1). \(result.name)\n"

                if let address = result.address {
                    output += "   Address: \(address)\n"
                }

                let distanceMiles = result.distance / 1609.34 // meters to miles
                output += "   Distance: \(String(format: "%.1f", distanceMiles)) miles\n"

                if let phone = result.phoneNumber {
                    output += "   Phone: \(phone)\n"
                }

                if let url = result.url {
                    output += "   URL: \(url.absoluteString)\n"
                }

                output += "\n"
            }

            // Create structured output
            let publicResults = results.map { MapSearchResult(from: $0, location: $0.location) }
            let structuredOutput = MapSearchToolOutput(results: publicResults)

            return ToolResult(content: output, structuredOutput: structuredOutput)
        } catch {
            return ToolResult(
                content: "Search failed: \(error.localizedDescription)",
                isError: true
            )
        }
    }

    public func formatCallSummary(input: MapSearchToolInput) -> String {
        if let location = input.location {
            return "search for \(input.query) near \(location)"
        } else {
            return "search for \(input.query) near current location"
        }
    }

    // MARK: - Private Helpers

    private func geocode(address: String) async throws -> CLLocation {
        guard let request = MKGeocodingRequest(addressString: address) else {
            throw MapSearchError.geocodingFailed
        }

        let mapItems = try await request.mapItems
        guard let mapItem = mapItems.first else {
            throw MapSearchError.geocodingFailed
        }

        return mapItem.location
    }

    private func search(query: String, near location: CLLocation, resultLimit: Int) async throws -> [SearchResult] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(
            center: location.coordinate,
            latitudinalMeters: 10000, // ~6 miles
            longitudinalMeters: 10000
        )
        request.resultTypes = .pointOfInterest

        let search = MKLocalSearch(request: request)
        let response = try await search.start()

        // Limit results and convert to our model
        return response.mapItems.prefix(resultLimit).map { mapItem in
            let distance = mapItem.location.distance(from: location)
            let address = mapItem.address?.fullAddress

            return SearchResult(
                name: mapItem.name ?? "Unknown",
                address: address,
                phoneNumber: mapItem.phoneNumber,
                url: mapItem.url,
                distance: distance,
                location: mapItem.location
            )
        }
    }
}

// MARK: - Input

public struct MapSearchToolInput: ToolInput {
    public let query: String
    public let location: String?
    public let resultLimit: Int

    public init(query: String, location: String? = nil, resultLimit: Int = 5) {
        self.query = query
        self.location = location
        self.resultLimit = resultLimit
    }

    public static var schema: JSONSchema {
        .object(
            properties: [
                "query": .string(description: "What to search for (e.g., 'coffee shops', 'gas stations', 'restaurants')"),
                "location": .string(description: "Address to search near. If not provided, uses the user's current location."),
                "resultLimit": .integer(description: "Maximum number of results to return (default: 5, max: 20)")
            ],
            required: ["query"]
        )
    }
}

// MARK: - Output

public struct MapSearchToolOutput: Codable, Sendable {
    public let results: [MapSearchResult]

    public init(results: [MapSearchResult]) {
        self.results = results
    }
}

// MARK: - Supporting Types

public struct MapSearchResult: Codable, Sendable {
    public let name: String
    public let address: String?
    public let phoneNumber: String?
    public let urlString: String?
    public let distance: CLLocationDistance
    public let latitude: Double
    public let longitude: Double

    fileprivate init(from searchResult: SearchResult, location: CLLocation) {
        self.name = searchResult.name
        self.address = searchResult.address
        self.phoneNumber = searchResult.phoneNumber
        self.urlString = searchResult.url?.absoluteString
        self.distance = searchResult.distance
        self.latitude = location.coordinate.latitude
        self.longitude = location.coordinate.longitude
    }
}

private struct SearchResult {
    let name: String
    let address: String?
    let phoneNumber: String?
    let url: URL?
    let distance: CLLocationDistance
    let location: CLLocation
}

private enum MapSearchError: LocalizedError {
    case geocodingFailed

    var errorDescription: String? {
        switch self {
        case .geocodingFailed:
            return "Could not find the specified location."
        }
    }
}

// MARK: - Permission Hook

/// Setup hook to request location permissions before tool execution when using current location
public func setupMapSearchPermissionHook(client: ClaudeClient, locationController: LocationController) async {
    await client.addHook(.beforeToolExecution) { (context: BeforeToolExecutionContext) async in
        guard context.toolName == MapSearchTool.name else { return }

        // Use input from context to check if location was provided
        guard let input = context.input as? MapSearchToolInput else {
            return
        }

        // Only request permission if no location address was provided
        if input.location == nil {
            await MainActor.run {
                locationController.requestPermission()
            }
        }
    }
}
