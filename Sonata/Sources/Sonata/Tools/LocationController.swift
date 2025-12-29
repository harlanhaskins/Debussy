//
//  LocationController.swift
//
//
//  Created by Harlan Haskins on 12/29/25.
//

import Foundation
import CoreLocation
@preconcurrency import MapKit
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Location Controller

/// Manages location services and permissions for the app
@MainActor
public class LocationController: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var locationContinuation: CheckedContinuation<CLLocation, Error>?

    public var authorizationStatus: CLAuthorizationStatus {
        manager.authorizationStatus
    }

    public var isAuthorized: Bool {
        switch authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            return true
        default:
            return false
        }
    }

    public override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    // MARK: - Permission Management

    /// Request location permission from the user
    public func requestPermission() {
        guard authorizationStatus == .notDetermined else { return }

        #if os(iOS)
        manager.requestWhenInUseAuthorization()
        #elseif os(macOS)
        manager.requestAlwaysAuthorization()
        #endif
    }

    /// Check if permission is granted, and return appropriate error message if not
    public func checkPermission() -> String? {
        switch authorizationStatus {
        case .notDetermined:
            return "Location permission has not been requested yet. Please grant location access when prompted."
        case .restricted:
            return "Location access is restricted. This may be due to parental controls or device management policies."
        case .denied:
            return "Location access is denied. Please enable location permissions in Settings to use this feature."
        case .authorizedWhenInUse, .authorizedAlways:
            return nil
        @unknown default:
            return "Unknown location authorization status."
        }
    }

    // MARK: - Location Access

    /// Fetch the user's current location
    /// - Throws: CLError if location cannot be determined
    public func currentLocation() async throws -> CLLocation {
        // Check permission first
        guard isAuthorized else {
            throw LocationError.permissionDenied
        }

        // Request fresh location
        manager.requestLocation()

        return try await withCheckedThrowingContinuation { continuation in
            self.locationContinuation = continuation
        }
    }

    /// Resolve address string for a location
    public func address(for location: CLLocation) async throws -> String {
        guard let request = MKReverseGeocodingRequest(location: location) else {
            throw LocationError.geocodingFailed
        }

        let mapItems = try await request.mapItems
        guard let mapItem = mapItems.first,
              let address = mapItem.address else {
            throw LocationError.geocodingFailed
        }

        // Use the full address, or short address if full is empty, or fallback message
        if !address.fullAddress.isEmpty {
            return address.fullAddress
        } else if let shortAddress = address.shortAddress, !shortAddress.isEmpty {
            return shortAddress
        } else {
            return "Address unavailable"
        }
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        Task { @MainActor in
            locationContinuation?.resume(returning: location)
            locationContinuation = nil
        }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            locationContinuation?.resume(throwing: error)
            locationContinuation = nil
        }
    }

    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // Notification for authorization changes
        // Could be used to update UI or retry operations
        Task { @MainActor in
            objectWillChange.send()
        }
    }
}

// MARK: - Location Error

public enum LocationError: LocalizedError {
    case permissionDenied
    case geocodingFailed

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Location permission is required to access location services."
        case .geocodingFailed:
            return "Could not determine address for location."
        }
    }
}
