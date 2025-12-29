//
//  Messaging.swift
//  
//
//  Created by Harlan Haskins on 3/29/24.
//

import Foundation
import SwiftClaude
import SwiftUI
import Textual
import UniformTypeIdentifiers
import WebKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct MessageView: View {
    var message: ConversationMessage

    var body: some View {
        VStack(alignment: message.isSent ? .trailing : .leading, spacing: 8) {
            ForEach(message.content) { content in
                switch content {
                case .text(let text):
                    // User messages in bubble, assistant messages inline
                    if message.kind == .user {
                        MessageBubble(kind: message.kind) {
                            Text(text)
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        #if os(iOS)
                        .contentShape(.contextMenuPreview, .rect(cornerRadius: 13))
                        #endif
                        .contentShape(.dragPreview, .rect(cornerRadius: 13))
                        .contextMenu {
                            Button {
                                #if canImport(UIKit)
                                UIPasteboard.general.setValue(text, forPasteboardType: UTType.plainText.identifier)
                                #elseif canImport(AppKit)
                                NSPasteboard.general.setString(text, forType: .string)
                                #endif
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                        }
                        .onDrag {
                            NSItemProvider(object: text as NSString)
                        }
                    } else {
                        // Assistant text inline (no bubble)
                        StructuredText(markdown: text)
                            .font(.body)
                            .fontDesign(.serif)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                case .toolExecution(let execution):
                    if execution.name == "WebCanvas", execution.isComplete, !execution.isError {
                        WebCanvasView(execution: execution)
                    } else {
                        ToolUseCard(execution: execution)
                    }
                }
            }
        }
    }
}

struct ToolUseCard: View {
    @Bindable var execution: ToolExecution
    @State private var showingDetail = false
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.displayScale) var displayScale

    var borderColor: Color {
        colorScheme == .dark ? .darkBorder : .lightBorder
    }

    var lastFourLines: String {
        let lines = execution.output.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(4).joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Tool name and input
            HStack {
                Text(execution.name)
                    .font(.headline)
                    .fontDesign(.monospaced)
                if !execution.input.isEmpty {
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(execution.input)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if !execution.isComplete {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }

            // Output preview (last 4 lines)
            if execution.isComplete {
                Text(lastFourLines.isEmpty ? "(no output)" : lastFourLines)
                    .font(.caption)
                    .fontDesign(.monospaced)
                    .foregroundStyle(execution.isError ? .red : .secondary)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Running...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .italic()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Color.secondary.opacity(0.1), in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(borderColor, style: StrokeStyle(lineWidth: 1 / displayScale))
        }
        .onTapGesture {
            showingDetail = true
        }
        .sheet(isPresented: $showingDetail) {
            ToolExecutionDetailView(execution: execution)
        }
    }
}

// MARK: - Tool Execution Detail Views

struct ToolExecutionDetailView: View {
    var execution: ToolExecution
    @Environment(\.dismiss) var dismiss

    var navigationTitle: String {
        switch execution.name {
        case JavaScriptTool.name: return "JavaScript"
        case WebCanvasTool.name: return "WebCanvas"
        case FetchTool.name: return "Fetch"
        default: return execution.name
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch execution.name {
                    case JavaScriptTool.name:
                        JavaScriptExecutionDetailContent(execution: execution)
                    case WebCanvasTool.name:
                        WebCanvasExecutionDetailContent(execution: execution)
                    case ReadTool.name, WriteTool.name, UpdateTool.name:
                        FileToolExecutionDetailContent(execution: execution)
                    case FetchTool.name:
                        FetchExecutionDetailContent(execution: execution)
                    default:
                        GenericToolExecutionDetailContent(execution: execution)
                    }
                }
                .padding()
            }
            .navigationTitle(navigationTitle)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct JavaScriptExecutionDetailContent: View {
    var execution: ToolExecution
    @State private var code: String?
    @State private var input: String?

    var body: some View {
        Group {
            // Code section
            if let code = code {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Code")
                        .font(.headline)
                    Text(code)
                        .font(.body)
                        .fontDesign(.monospaced)
                        .textSelection(.enabled)
                }
            }

            // Input JSON section
            if let input = input {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Input JSON")
                        .font(.headline)
                    Text(input)
                        .font(.body)
                        .fontDesign(.monospaced)
                        .textSelection(.enabled)
                }
            }

            // Output section
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Result")
                        .font(.headline)
                    if !execution.isComplete {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Running...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if execution.isComplete {
                    Text(execution.output.isEmpty ? "(no output)" : execution.output)
                        .font(.body)
                        .fontDesign(.monospaced)
                        .foregroundStyle(execution.isError ? .red : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .onAppear {
            guard let inputData = execution.inputData else { return }
            do {
                let decoder = JSONDecoder()
                let decoded = try decoder.decode(JavaScriptToolInput.self, from: inputData)
                code = decoded.code
                input = decoded.input
            } catch {
                code = "Error decoding input: \(error.localizedDescription)"
            }
        }
    }
}

struct WebCanvasExecutionDetailContent: View {
    var execution: ToolExecution
    @State private var html: String?
    @State private var aspectRatio: String?
    @State private var input: String?

    var body: some View {
        Group {
            // Aspect ratio
            if let aspectRatio = aspectRatio {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Aspect Ratio")
                        .font(.headline)
                    Text(aspectRatio)
                        .font(.body)
                        .textSelection(.enabled)
                }
            }

            // HTML content
            if let html = html {
                VStack(alignment: .leading, spacing: 4) {
                    Text("HTML")
                        .font(.headline)
                    Text(html)
                        .font(.body)
                        .fontDesign(.monospaced)
                        .textSelection(.enabled)
                }
            }

            // Input JSON section
            if let input = input {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Input JSON")
                        .font(.headline)
                    Text(input)
                        .font(.body)
                        .fontDesign(.monospaced)
                        .textSelection(.enabled)
                }
            }

            // File path
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("File Path")
                        .font(.headline)
                    if !execution.isComplete {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Creating...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if execution.isComplete {
                    let displayOutput = {
                        // Extract and make file path relative
                        guard let firstLine = execution.output.split(separator: "\n").first,
                              let pathStart = firstLine.range(of: "Created canvas at ")?.upperBound else {
                            return execution.output
                        }

                        let fullPath = String(firstLine[pathStart...])
                        let relativePath = makePathRelative(fullPath)
                        var result = "Created canvas at \(relativePath)"
                        if let aspectLine = execution.output.split(separator: "\n").dropFirst().first {
                            result += "\n\(aspectLine)"
                        }
                        return result
                    }()

                    Text(displayOutput)
                        .font(.body)
                        .fontDesign(.monospaced)
                        .foregroundStyle(execution.isError ? .red : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .onAppear {
            guard let inputData = execution.inputData else { return }
            do {
                let decoder = JSONDecoder()
                let decoded = try decoder.decode(WebCanvasToolInput.self, from: inputData)
                html = decoded.html
                aspectRatio = decoded.aspectRatio ?? "1:1"
                input = decoded.input
            } catch {
                html = "Error decoding input: \(error.localizedDescription)"
            }
        }
    }
}

struct FileToolExecutionDetailContent: View {
    var execution: ToolExecution
    @Environment(\.claudeClient) private var client
    @State private var filePath: String?
    @State private var fileContents: String?

    var outputLabel: String {
        switch execution.name {
        case "Read": return "File Contents"
        case "Write": return "Written Content"
        case "Update": return "Updated Content"
        default: return "File Contents"
        }
    }

    var body: some View {
        Group {
            // File path
            if let filePath = filePath {
                VStack(alignment: .leading, spacing: 4) {
                    Text("File Path")
                        .font(.headline)
                    Text(makePathRelative(filePath))
                        .font(.body)
                        .fontDesign(.monospaced)
                        .textSelection(.enabled)
                }
            }

            // File contents
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(outputLabel)
                        .font(.headline)
                    if !execution.isComplete {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Loading...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if execution.isComplete {
                    let displayText = if let fileContents {
                        fileContents
                    } else {
                        execution.output.isEmpty ? "(no output)" : execution.output
                    }

                    Text(displayText)
                        .font(.body)
                        .fontDesign(.monospaced)
                        .foregroundStyle(execution.isError ? .red : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .task {
            guard let client = client,
                  let inputData = execution.inputData else { return }

            let extractedPath = await client.extractFilePath(
                toolName: execution.name,
                input: ToolInput(data: inputData)
            )
            filePath = extractedPath

            if let extractedPath = extractedPath {
                do {
                    let contents = try String(contentsOfFile: extractedPath, encoding: .utf8)
                    fileContents = contents
                } catch {
                    fileContents = "Error reading file: \(error.localizedDescription)"
                }
            }
        }
    }
}

struct FetchExecutionDetailContent: View {
    var execution: ToolExecution
    @State private var url: String?

    var body: some View {
        Group {
            // URL
            if let url = url {
                VStack(alignment: .leading, spacing: 4) {
                    Text("URL")
                        .font(.headline)
                    Text(url)
                        .font(.body)
                        .textSelection(.enabled)
                }
            }

            // Response
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Response")
                        .font(.headline)
                    if !execution.isComplete {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Fetching...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if execution.isComplete {
                    Text(execution.output.isEmpty ? "(no output)" : execution.output)
                        .font(.body)
                        .fontDesign(.monospaced)
                        .foregroundStyle(execution.isError ? .red : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .onAppear {
            guard let inputData = execution.inputData else { return }
            do {
                let decoder = JSONDecoder()
                let decoded = try decoder.decode(FetchToolInput.self, from: inputData)
                url = decoded.url
            } catch {
                url = "Error decoding input: \(error.localizedDescription)"
            }
        }
    }
}

struct GenericToolExecutionDetailContent: View {
    var execution: ToolExecution

    var body: some View {
        Group {
            // Input section
            if !execution.input.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Input")
                        .font(.headline)
                    Text(execution.input)
                        .font(.body)
                        .fontDesign(.monospaced)
                        .textSelection(.enabled)
                }
            }

            // Output section
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Output")
                        .font(.headline)
                    if !execution.isComplete {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Running...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if execution.isComplete {
                    Text(execution.output.isEmpty ? "(no output)" : execution.output)
                        .font(.body)
                        .fontDesign(.monospaced)
                        .foregroundStyle(execution.isError ? .red : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

struct EllipsisView: View {
    @State var pulseGeneration = 0
    var body: some View {
        MessageBubble(kind: .assistant) {
            Image(systemName: "ellipsis")
                .frame(minHeight: 26)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .symbolEffect(.bounce, value: pulseGeneration)
        }
        .task {
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(1))
                    pulseGeneration &+= 1
                }
            } catch {
                // Just stop pulsing on cancellation errors.
            }
        }
    }
}

struct MessageBubble<Content: View>: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.displayScale) var displayScale
    var kind: ConversationMessage.Kind
    @ViewBuilder var content: Content

    var borderColor: Color {
        colorScheme == .dark ? .darkBorder : .lightBorder
    }

    var isSent: Bool {
        kind == .user
    }

    var background: AnyShapeStyle {
        switch colorScheme {
        case .dark:
            isSent ? AnyShapeStyle(Color.darkSentMessageBackground) : AnyShapeStyle(Color.darkReceivedMessageBackground)
        case .light:
            isSent ? AnyShapeStyle(Color.lightSentMessageBackground) : AnyShapeStyle(Color.lightReceivedMessageBackground)
        default: AnyShapeStyle(Color.lightSentMessageBackground)
        }
    }

    var foregroundStyle: AnyShapeStyle {
        switch kind {
        case .user, .assistant: AnyShapeStyle(.primary)
        case .error: AnyShapeStyle(.secondary)
        }
    }

    var body: some View {
        content
            .font(.body)
            .fontDesign(isSent ? .default : .serif)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(background, in: .rect(cornerRadius: 13))
            .overlay {
                RoundedRectangle(cornerRadius: 13)
                    .strokeBorder(borderColor, style: StrokeStyle(lineWidth: 1 / displayScale))
            }
            .foregroundStyle(foregroundStyle)
            .transition(.scale(scale: 0.95, anchor: isSent ? .trailing : .leading).combined(with: .opacity).animation(.snappy))
    }
}

struct WebCanvasView: View {
    @Bindable var execution: ToolExecution
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.displayScale) var displayScale
    @State private var aspectRatio: CGFloat = 1.0

    var borderColor: Color {
        colorScheme == .dark ? .darkBorder : .lightBorder
    }

    var filePath: String? {
        // Extract file path from output (format: "Created canvas at <path>\n...")
        guard let line = execution.output.split(separator: "\n").first,
              let pathStart = line.range(of: "Created canvas at ")?.upperBound else {
            return nil
        }
        return String(line[pathStart...])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let path = filePath {
                let url = URL(filePath: path)
                WebView(url: url)
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .frame(maxWidth: 600)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(borderColor, style: StrokeStyle(lineWidth: 1 / displayScale))
                    }
                    .task {
                        // Parse aspect ratio from output
                        if let aspectLine = execution.output.split(separator: "\n").first(where: { $0.contains("Aspect ratio:") }),
                           let ratioStart = aspectLine.range(of: "Aspect ratio: ")?.upperBound {
                            let ratioString = String(aspectLine[ratioStart...])
                            let components = ratioString.split(separator: ":").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                            if components.count == 2, components[1] > 0 {
                                aspectRatio = components[0] / components[1]
                            }
                        }
                    }
            } else {
                Text("Failed to load canvas")
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
    }
}
