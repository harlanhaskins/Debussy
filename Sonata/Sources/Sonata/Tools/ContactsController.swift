//
//  ContactsController.swift
//
//
//  Created by Claude on 12/30/25.
//

import Foundation
@preconcurrency import Contacts
import SwiftUI
import SwiftCEL

// MARK: - Contacts Controller

/// Manages contacts access and searching for the app
@MainActor @Observable
public class ContactsController {
    private nonisolated let store = CNContactStore()

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

    /// Filter contacts using a CEL expression
    /// - Parameters:
    ///   - expression: CEL expression to filter contacts
    ///   - limit: Maximum number of results to return
    /// - Returns: Array of matching contacts
    public func filterContacts(expression: String, limit: Int) async throws -> [ContactResult] {
        guard isAuthorized else {
            throw ContactsError.permissionDenied
        }

        // Parse CEL expression
        let expr = try Parser.parse(expression)

        // Enumerate ALL contacts once and filter with CEL
        let matchedContacts = try await enumerateAndFilterContacts(
            expr: expr,
            limit: limit
        )

        return matchedContacts
    }

    @concurrent
    private nonisolated func enumerateAndFilterContacts(
        expr: any Expr,
        limit: Int
    ) async throws -> [ContactResult] {
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPostalAddressesKey as CNKeyDescriptor,
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName)
        ]

        var matchedContacts: [ContactResult] = []
        let fetchRequest = CNContactFetchRequest(keysToFetch: keysToFetch)

        // Create evaluator with default registry
        let evaluator = Evaluator()

        // Enumerate all contacts once and filter with CEL
        try store.enumerateContacts(with: fetchRequest) { contact, stop in
            // Convert to ContactResult
            let contactResult = Self.convertContact(contact, query: "")

            // Create CEL context with contact fields
            let contactValue = contactResult.toCELValue()
            guard let contactMap = contactValue.asMap else { return }

            let context = Context(bindings: contactMap)

            // Evaluate CEL expression
            do {
                let result = try evaluator.evaluate(expr, in: context)
                if result.isTruthy {
                    matchedContacts.append(contactResult)

                    // Stop if we've reached the limit
                    if matchedContacts.count >= limit {
                        stop.pointee = true
                    }
                }
            } catch {
                // Skip contacts that fail evaluation
                return
            }
        }

        return matchedContacts
    }

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
        var results = matchingContacts.map { Self.convertContact($0, query: query) }

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

    /// Add a new contact to the user's contacts
    /// - Parameters:
    ///   - givenName: First name
    ///   - familyName: Last name
    ///   - phoneNumbers: Phone numbers with optional labels
    ///   - emailAddresses: Email addresses
    ///   - organization: Company/organization name
    /// - Returns: The created contact's identifier
    public func addContact(
        givenName: String?,
        familyName: String?,
        phoneNumbers: [(label: String?, number: String)]?,
        emailAddresses: [String]?,
        organization: String?
    ) async throws -> String {
        guard isAuthorized else {
            throw ContactsError.permissionDenied
        }

        let contact = CNMutableContact()

        if let givenName = givenName {
            contact.givenName = givenName
        }
        if let familyName = familyName {
            contact.familyName = familyName
        }
        if let organization = organization {
            contact.organizationName = organization
        }

        if let phoneNumbers = phoneNumbers {
            contact.phoneNumbers = phoneNumbers.map { phone in
                let phoneNumber = CNPhoneNumber(stringValue: phone.number)
                let label = phone.label ?? CNLabelPhoneNumberMain
                return CNLabeledValue(label: label, value: phoneNumber)
            }
        }

        if let emailAddresses = emailAddresses {
            contact.emailAddresses = emailAddresses.enumerated().map { index, email in
                let label = index == 0 ? CNLabelHome : CNLabelWork
                return CNLabeledValue(label: label, value: email as NSString)
            }
        }

        let saveRequest = CNSaveRequest()
        saveRequest.add(contact, toContainerWithIdentifier: nil)

        try store.execute(saveRequest)

        return contact.identifier
    }

    // MARK: - Private Helpers

    private static nonisolated func convertContact(
        _ contact: CNContact,
        query: String
    ) -> ContactResult {
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

// MARK: - CEL Conversion

extension ContactResult {
    /// Convert contact to a CEL Value for expression evaluation
    func toCELValue() -> Value {
        var contact: [String: Value] = [:]

        contact["id"] = .string(id)
        contact["displayName"] = .string(displayName)
        contact["givenName"] = givenName.map { .string($0) } ?? .null
        contact["familyName"] = familyName.map { .string($0) } ?? .null

        // Phone numbers as list of maps
        let phones: [Value] = phoneNumbers.map { phone in
            var phoneMap: [String: Value] = ["number": .string(phone.number)]
            if let label = phone.label {
                phoneMap["label"] = .string(label)
            }
            return .map(phoneMap)
        }
        contact["phoneNumbers"] = .list(phones)

        // Email addresses as list of strings
        contact["emailAddresses"] = .list(emailAddresses.map { .string($0) })

        // Postal addresses as list of maps
        let addresses: [Value] = postalAddresses.map { address in
            var addrMap: [String: Value] = [
                "formattedAddress": .string(address.formattedAddress)
            ]
            if let label = address.label {
                addrMap["label"] = .string(label)
            }
            if let street = address.street {
                addrMap["street"] = .string(street)
            }
            if let city = address.city {
                addrMap["city"] = .string(city)
            }
            if let state = address.state {
                addrMap["state"] = .string(state)
            }
            if let postalCode = address.postalCode {
                addrMap["postalCode"] = .string(postalCode)
            }
            if let country = address.country {
                addrMap["country"] = .string(country)
            }
            return .map(addrMap)
        }
        contact["postalAddresses"] = .list(addresses)

        return .map(contact)
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
