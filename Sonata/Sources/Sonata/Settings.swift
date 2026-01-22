//
//  Settings.swift
//
//
//  Created by Claude on 12/28/24.
//

import Foundation
import SwiftClaude
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @Binding var apiKey: String
    @Binding var customInstructions: String
    @Binding var selectedModel: String
    @Binding var mcpServers: [MCPServerConfiguration]
    var onDeleteAllData: () -> Void

    @State private var showingAddServer = false
    @State private var showingDeleteConfirmation = false

    private let availableModels = [
        "claude-sonnet-4-5",
        "claude-opus-4-5",
        "claude-haiku-4-5"
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("API Key") {
                    SecureField("Anthropic API Key", text: $apiKey)
                        .font(.body)
                        .fontDesign(.monospaced)
                }

                Section {
                    Picker("Model", selection: $selectedModel) {
                        ForEach(availableModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                } header: {
                    Text("Model")
                } footer: {
                    Text("Select the Claude model to use for new conversations")
                        .font(.caption)
                }

                Section {
                    TextEditor(text: $customInstructions)
                        .font(.body)
                        .frame(minHeight: 100)
                } header: {
                    Text("Custom Instructions")
                } footer: {
                    Text("These instructions will be included in the system prompt for all conversations")
                        .font(.caption)
                }

                Section {
                    ForEach(mcpServers) { server in
                        MCPServerRow(server: server)
                    }
                    .onDelete { indexSet in
                        mcpServers.remove(atOffsets: indexSet)
                    }

                    Button {
                        showingAddServer = true
                    } label: {
                        Label("Add HTTP Server", systemImage: "plus.circle")
                    }
                } header: {
                    Text("MCP Servers")
                } footer: {
                    Text("Only HTTP MCP servers are supported on iOS")
                        .font(.caption)
                }

                Section {
                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Label("Delete All Data", systemImage: "trash")
                    }
                } footer: {
                    Text("This will delete all conversations, files, and reset all settings")
                        .font(.caption)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showingAddServer) {
                AddMCPServerView(servers: $mcpServers)
            }
            .confirmationDialog(
                "Delete All Data?",
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete All Data", role: .destructive) {
                    onDeleteAllData()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete all conversations, files, MCP servers, and reset all settings. This cannot be undone.")
            }
        }
    }
}

struct MCPServerRow: View {
    let server: MCPServerConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(server.name)
                .font(.headline)
            if let description = server.description, !description.isEmpty {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text(server.url)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }
}

struct AddMCPServerView: View {
    @Environment(\.dismiss) var dismiss
    @Binding var servers: [MCPServerConfiguration]

    @State private var name = ""
    @State private var url = ""
    @State private var description = ""
    @State private var isProbing = false
    @State private var probeError: String?
    @State private var serverVersion: String?

    var isValid: Bool {
        !name.isEmpty && !url.isEmpty && url.hasPrefix("http")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server Details") {
                    TextField("URL", text: $url)
                        .autocorrectionDisabled()
                        .textContentType(.URL)
                        .onChange(of: url) { _, newValue in
                            // Clear probe state when URL changes
                            probeError = nil
                            serverVersion = nil
                        }

                    if isProbing {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Connecting to server...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if let error = probeError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else if let version = serverVersion {
                        Text("Connected • Version \(version)")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else if url.hasPrefix("http") {
                        Button("Test Connection") {
                            Task {
                                await probeServer()
                            }
                        }
                        .font(.caption)
                    }

                    TextField("Name", text: $name)
                        .autocorrectionDisabled()

                    TextField("Description (optional)", text: $description)
                }

                Section {
                    Text("Only HTTP/HTTPS URLs are supported. Test the connection to auto-fill the server name.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add MCP Server")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        servers.append(MCPServerConfiguration(
                            id: UUID(),
                            name: name,
                            url: url,
                            description: description.isEmpty ? nil : description
                        ))
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
    }

    private func probeServer() async {
        isProbing = true
        probeError = nil
        serverVersion = nil

        do {
            let result = try await MCPManager.probe(url: url)
            serverVersion = result.version
            // Auto-fill name if empty
            if name.isEmpty {
                name = result.name
            }
        } catch {
            probeError = error.localizedDescription
        }

        isProbing = false
    }
}

// MARK: - Data Models

struct MCPServerConfiguration: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var url: String
    var description: String?
}
