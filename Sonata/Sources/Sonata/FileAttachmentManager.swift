//
//  FileAttachmentManager.swift
//
//
//  Created by Claude on 1/2/26.
//

import Foundation
import System
import SwiftClaude

/// Manages file attachments for conversations
struct FileAttachmentManager {
    private let conversationDirectory: FilePath

    init(conversationDirectory: FilePath) {
        self.conversationDirectory = conversationDirectory
    }

    /// Copy a file to the attachments directory for a specific message
    /// - Parameters:
    ///   - sourceURL: The source file URL
    ///   - messageId: The message ID to associate the attachment with
    /// - Returns: A FileAttachment with metadata
    /// - Throws: FileAttachmentError if the copy fails
    func copyFile(from sourceURL: URL, toMessageId messageId: UUID) throws -> FileAttachment {
        let fileName = sourceURL.lastPathComponent
        let messageAttachmentsDir = conversationDirectory
            .appending("attachments")
            .appending(messageId.uuidString)

        // Create attachments directory if needed
        try createDirectoryIfNeeded(messageAttachmentsDir)

        // Handle duplicate filenames by appending a number
        let destinationFileName = try uniqueFileName(fileName, in: messageAttachmentsDir)
        let destinationPath = messageAttachmentsDir.appending(destinationFileName)

        // Copy the file
        let fileManager = FileManager.default
        try fileManager.copyItem(
            atPath: sourceURL.path,
            toPath: destinationPath.string
        )

        // Get file attributes
        let attributes = try fileManager.attributesOfItem(atPath: destinationPath.string)
        let fileSize = attributes[.size] as? Int ?? 0

        // Detect MIME type
        let mimeType = SwiftClaude.FileAttachmentUtilities.mimeType(for: destinationPath) ?? "application/octet-stream"

        return FileAttachment(
            id: UUID(),
            path: destinationPath,
            fileName: destinationFileName,
            mimeType: mimeType,
            fileSize: fileSize
        )
    }

    /// Delete all attachments for a specific message
    /// - Parameter messageId: The message ID whose attachments should be deleted
    func deleteAttachments(forMessageId messageId: UUID) throws {
        let messageAttachmentsDir = conversationDirectory
            .appending("attachments")
            .appending(messageId.uuidString)

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: messageAttachmentsDir.string) {
            try fileManager.removeItem(atPath: messageAttachmentsDir.string)
        }
    }

    /// Create a SwiftClaude ContentBlock from a FileAttachment
    /// - Parameter attachment: The file attachment
    /// - Returns: A ContentBlock representing the attachment
    /// - Throws: FileAttachmentError if the file cannot be read
    func createContentBlock(for attachment: FileAttachment) throws -> SwiftClaude.ContentBlock {
        return try FileAttachmentUtilities.createContentBlock(for: attachment.path)
    }

    // MARK: - Private Helpers

    private func createDirectoryIfNeeded(_ path: FilePath) throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: path.string) {
            try fileManager.createDirectory(
                atPath: path.string,
                withIntermediateDirectories: true
            )
        }
    }

    private func uniqueFileName(_ fileName: String, in directory: FilePath) throws -> String {
        let fileManager = FileManager.default
        var candidateFileName = fileName
        var counter = 1

        // Extract name and extension
        let nameComponents = fileName.split(separator: ".", maxSplits: 1)
        let baseName = String(nameComponents.first ?? "")
        let fileExtension = nameComponents.count > 1 ? String(nameComponents.last!) : ""

        while fileManager.fileExists(atPath: directory.appending(candidateFileName).string) {
            if fileExtension.isEmpty {
                candidateFileName = "\(baseName) (\(counter))"
            } else {
                candidateFileName = "\(baseName) (\(counter)).\(fileExtension)"
            }
            counter += 1
        }

        return candidateFileName
    }
}
