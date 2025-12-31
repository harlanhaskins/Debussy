//
//  ContactsController.swift
//
//
//  Created by Claude on 12/30/25.
//

import Foundation
@preconcurrency import Contacts
import SwiftUI

// MARK: - Contacts Controller

/// Manages contacts access and searching for the app
@MainActor @Observable
public class ContactsController {
    private let store = CNContactStore()

    public var authorizationStatus: CNAuthorizationStatus {
        CNContactStore.authorizationStatus(for: .contacts)
    }

    public var isAuthorized: Bool {
        authorizationStatus == .authorized
    }

    public init() {}

    // MARK: - Permission Management

    /// Request contacts permission from the user
    public func requestPermission() async {
        guard authorizationStatus == .notDetermined else { return }
        _ = try? await store.requestAccess(for: .contacts)
    }

    /// Check if permission is granted, and return appropriate error message if not
    public func checkPermission() -> String? {
        switch authorizationStatus {
        case .notDetermined:
            "Contacts permission has not been requested yet. Please grant contacts access when prompted."
        case .restricted:
            "Contacts access is restricted. This may be due to parental controls or device management policies."
        case .denied:
            "Contacts access is denied. Please enable contacts permissions in Settings to use this feature."
        case .authorized, .limited:
            nil
        @unknown default:
            "Unknown contacts authorization status."
        }
    }

    // MARK: - Search

    /// Search contacts by query string
    /// - Parameters:
    ///   - query: Search query (searches across name, email, phone)
    ///   - limit: Maximum number of results to return
    /// - Returns: Array of matching contacts
    public func searchContacts(query: String, limit: Int) async throws -> [ContactResult] {
        guard isAuthorized else {
            throw ContactsError.permissionDenied
        }

        let matchingContacts = try await enumerateMatchingContacts(
            store: store,
            query: query,
            limit: limit
        )

        // Convert and sort by relevance
        var results = matchingContacts.map { convertContact($0, query: query) }

        // Sort: exact name matches first, then partial, then email/phone matches
        results.sort { lhs, rhs in
            let lhsExact = lhs.displayName.lowercased() == query.lowercased()
            let rhsExact = rhs.displayName.lowercased() == query.lowercased()
            if lhsExact != rhsExact { return lhsExact }

            let lhsStarts = lhs.displayName.lowercased().hasPrefix(query.lowercased())
            let rhsStarts = rhs.displayName.lowercased().hasPrefix(query.lowercased())
            if lhsStarts != rhsStarts { return lhsStarts }

            return lhs.displayName < rhs.displayName
        }

        // Limit results
        return Array(results.prefix(limit))
    }

    @concurrent
    nonisolated private func enumerateMatchingContacts(
        store: CNContactStore,
        query: String,
        limit: Int
    ) async throws -> [CNContact] {
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPostalAddressesKey as CNKeyDescriptor,
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName)
        ]

        var matchingContacts: [CNContact] = []
        let fetchRequest = CNContactFetchRequest(keysToFetch: keysToFetch)
        let queryLower = query.lowercased()

        // Single pass: check name, email, and phone
        try store.enumerateContacts(with: fetchRequest) { contact, stop in
            let nameMatch = CNContactFormatter.string(from: contact, style: .fullName)?
                .lowercased()
                .contains(queryLower) ?? false

            let emailMatch = contact.emailAddresses.contains { emailAddress in
                (emailAddress.value as String).lowercased().contains(queryLower)
            }

            let phoneMatch = contact.phoneNumbers.contains { phoneNumber in
                phoneNumber.value.stringValue.contains(query)
            }

            if nameMatch || emailMatch || phoneMatch {
                matchingContacts.append(contact)

                // Stop early if we have enough results
                if matchingContacts.count >= limit * 2 {
                    stop.pointee = true
                }
            }
        }

        return matchingContacts
    }

    // MARK: - Private Helpers

    private func convertContact(_ contact: CNContact, query: String) -> ContactResult {
        let formatter = CNContactFormatter()
        formatter.style = .fullName
        let displayName = formatter.string(from: contact) ?? "Unknown"

        let phoneNumbers = contact.phoneNumbers.map { labeledValue in
            PhoneNumber(
                label: labeledValue.label.flatMap { CNLabeledValue<NSString>.localizedString(forLabel: $0) },
                number: labeledValue.value.stringValue
            )
        }

        let emailAddresses = contact.emailAddresses.map { $0.value as String }

        let postalAddresses = contact.postalAddresses.map { labeledValue in
            let address = labeledValue.value
            let formatter = CNPostalAddressFormatter()
            let formattedAddress = formatter.string(from: address)

            return PostalAddress(
                label: labeledValue.label.flatMap { CNLabeledValue<NSString>.localizedString(forLabel: $0) },
                street: address.street.isEmpty ? nil : address.street,
                city: address.city.isEmpty ? nil : address.city,
                state: address.state.isEmpty ? nil : address.state,
                postalCode: address.postalCode.isEmpty ? nil : address.postalCode,
                country: address.country.isEmpty ? nil : address.country,
                formattedAddress: formattedAddress
            )
        }

        return ContactResult(
            id: contact.identifier,
            displayName: displayName,
            givenName: contact.givenName.isEmpty ? nil : contact.givenName,
            familyName: contact.familyName.isEmpty ? nil : contact.familyName,
            phoneNumbers: phoneNumbers,
            emailAddresses: emailAddresses,
            postalAddresses: postalAddresses
        )
    }
}

// MARK: - Contact Result

public struct ContactResult: Codable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let givenName: String?
    public let familyName: String?
    public let phoneNumbers: [PhoneNumber]
    public let emailAddresses: [String]
    public let postalAddresses: [PostalAddress]

    public init(
        id: String,
        displayName: String,
        givenName: String?,
        familyName: String?,
        phoneNumbers: [PhoneNumber],
        emailAddresses: [String],
        postalAddresses: [PostalAddress]
    ) {
        self.id = id
        self.displayName = displayName
        self.givenName = givenName
        self.familyName = familyName
        self.phoneNumbers = phoneNumbers
        self.emailAddresses = emailAddresses
        self.postalAddresses = postalAddresses
    }
}

public struct PhoneNumber: Codable, Sendable {
    public let label: String?
    public let number: String

    public init(label: String?, number: String) {
        self.label = label
        self.number = number
    }
}

public struct PostalAddress: Codable, Sendable {
    public let label: String?
    public let street: String?
    public let city: String?
    public let state: String?
    public let postalCode: String?
    public let country: String?
    public let formattedAddress: String

    public init(
        label: String?,
        street: String?,
        city: String?,
        state: String?,
        postalCode: String?,
        country: String?,
        formattedAddress: String
    ) {
        self.label = label
        self.street = street
        self.city = city
        self.state = state
        self.postalCode = postalCode
        self.country = country
        self.formattedAddress = formattedAddress
    }
}

// MARK: - Contacts Error

public enum ContactsError: LocalizedError {
    case permissionDenied

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Contacts permission is required to search contacts."
        }
    }
}
