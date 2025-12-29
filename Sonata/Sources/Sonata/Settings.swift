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
    @Binding var mcpServers: [MCPServerConfiguration]

    @State private var showingAddServer = false

    var body: some View {
        NavigationStack {
            Form {
                Section("API Key") {
                    SecureField("Anthropic API Key", text: $apiKey)
                        .font(.body)
                        .fontDesign(.monospaced)
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
        }
    }
}

struct MCPServerRow: View {
    let server: MCPServerConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(server.name)
                .font(.headline)
            Text(server.url)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

struct AddMCPServerView: View {
    @Environment(\.dismiss) var dismiss
    @Binding var servers: [MCPServerConfiguration]

    @State private var name = ""
    @State private var url = ""

    var isValid: Bool {
        !name.isEmpty && !url.isEmpty && url.hasPrefix("http")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server Details") {
                    TextField("Name", text: $name)
                        .autocorrectionDisabled()

                    TextField("URL", text: $url)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                }

                Section {
                    Text("Only HTTP/HTTPS URLs are supported")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add MCP Server")
            .navigationBarTitleDisplayMode(.inline)
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
                            url: url
                        ))
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
    }
}

// MARK: - Data Models

struct MCPServerConfiguration: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var url: String
}
