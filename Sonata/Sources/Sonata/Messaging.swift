//
//  Messaging.swift
//  
//
//  Created by Harlan Haskins on 3/29/24.
//

import Foundation
import SwiftClaude
import SwiftUI
import System
import Textual
import UniformTypeIdentifiers
import WebKit
@preconcurrency import MapKit

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

                case .thinking(let thinking):
                    // Thinking blocks displayed with caption font and secondary style
                    Text(thinking.thinking)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                case .toolExecution(let execution):
                    if execution.name == "WebCanvas", execution.isComplete, !execution.isError {
                        WebCanvasView(execution: execution)
                    } else if execution.name == "MapSearch", execution.isComplete, !execution.isError, execution.decodedOutput != nil {
                        MapSearchView(execution: execution)
                    } else {
                        ToolUseCard(execution: execution)
                    }

                case .fileAttachment(let attachment):
                    FileAttachmentView(attachment: attachment, messageKind: message.kind)
                }
            }
        }
    }
}

struct ToolUseCard: View {
    @Bindable var execution: ToolExecution
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.displayScale) var displayScale

    var borderColor: Color {
        colorScheme == .dark ? .darkBorder : .lightBorder
    }

    var lastFourLines: String {
        let lines = execution.output.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(4).joined(separator: "\n")
    }

    var recentSubToolCalls: [ToolExecution] {
        Array(execution.subToolExecutions.suffix(3))
    }

    var filePath: FilePath? {
        if let fileInput = execution.decodedInput as? FileToolInput {
            return fileInput.filePath
        }
        if let canvasOutput = execution.decodedOutput as? WebCanvasOutput {
            return canvasOutput.filePath
        }
        return nil
    }

    var body: some View {
        NavigationLink {
            ToolExecutionDetailView(execution: execution)
        } label: {
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

                    // File tool menu
                    if let filePath = filePath {
                        FileToolMenu(filePath: filePath)
                    }
                }

                // For SubAgent: show recent tool calls
                if execution.name == "SubAgent" && !execution.subToolExecutions.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(recentSubToolCalls) { subExecution in
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Text(subExecution.name)
                                    .font(.caption)
                                    .fontDesign(.monospaced)
                                    .fontWeight(.medium)
                                Text("·")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                Text(subExecution.input)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        if !execution.isComplete {
                            Text("Running...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .italic()
                        }
                    }
                } else {
                    // Output preview (last 4 lines) for non-SubAgent tools
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
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(Color.secondary.opacity(0.1), in: .rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(borderColor, style: StrokeStyle(lineWidth: 1 / displayScale))
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Tool Execution Detail Views

struct ToolExecutionDetailView: View {
    var execution: ToolExecution

    var navigationTitle: String {
        switch execution.name {
        case JavaScriptTool.name: return "JavaScript"
        case WebCanvasTool.name: return "WebCanvas"
        case SubAgentTool.name: return "SubAgent"
        case FetchTool.name: return "Fetch"
        default: return execution.name
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch execution.name {
                case JavaScriptTool.name:
                    JavaScriptExecutionDetailContent(execution: execution)
                case WebCanvasTool.name:
                    WebCanvasExecutionDetailContent(execution: execution)
                case SubAgentTool.name:
                    SubAgentExecutionDetailContent(execution: execution)
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
    }
}

struct JavaScriptExecutionDetailContent: View {
    var execution: ToolExecution

    var decodedInput: JavaScriptToolInput? {
        execution.decodedInput as? JavaScriptToolInput
    }

    var body: some View {
        Group {
            // Input summary (fallback when decodedInput is unavailable)
            if decodedInput == nil && !execution.input.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Input")
                        .font(.headline)
                    Text(execution.input)
                        .font(.body)
                        .fontDesign(.monospaced)
                        .textSelection(.enabled)
                }
            }

            // Code section
            if let code = decodedInput?.code {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Code", systemImage: "chevron.left.forwardslash.chevron.right")
                        .font(.headline)

                    let markdown = "```javascript\n\(code)\n```"
                    StructuredText(markdown: markdown)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
    }
}

struct WebCanvasExecutionDetailContent: View {
    var execution: ToolExecution

    var decodedInput: WebCanvasToolInput? {
        execution.decodedInput as? WebCanvasToolInput
    }

    var body: some View {
        Group {
            // Input summary (fallback when decodedInput is unavailable)
            if decodedInput == nil && !execution.input.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Input")
                        .font(.headline)
                    Text(execution.input)
                        .font(.body)
                        .fontDesign(.monospaced)
                        .textSelection(.enabled)
                }
            }

            // Aspect ratio
            if let aspectRatio = decodedInput?.aspectRatio ?? "1:1" as String? {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Aspect Ratio")
                        .font(.headline)
                    Text(aspectRatio)
                        .font(.body)
                        .textSelection(.enabled)
                }
            }

            // HTML content
            if let html = decodedInput?.html {
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
            if let input = decodedInput?.input {
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
                        var result = "Created canvas at \(fullPath)"
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
    }
}

struct SubAgentExecutionDetailContent: View {
    var execution: ToolExecution

    var decodedOutput: SubAgentBatchResult? {
        execution.decodedOutput as? SubAgentBatchResult
    }

    var body: some View {
        Group {
            // Summary section
            if !execution.output.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Summary", systemImage: "text.alignleft")
                        .font(.headline)

                    StructuredText(markdown: execution.output)
                }
            }

            // Tool calls section (from live execution tracking)
            if !execution.subToolExecutions.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Sub-Tool Calls", systemImage: "wrench.and.screwdriver")
                            .font(.headline)
                        Spacer()
                        Text("\(execution.subToolExecutions.count) calls")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    LazyVStack(spacing: 8) {
                        ForEach(execution.subToolExecutions) { subExecution in
                            ToolUseCard(execution: subExecution)
                        }
                    }
                }
            } else if let batchResult = decodedOutput, !batchResult.results.isEmpty {
                // Fallback to batch result if no live executions (for restored sessions)
                VStack(alignment: .leading, spacing: 12) {
                    Label("Sub-Agent Tool Calls", systemImage: "wrench.and.screwdriver")
                        .font(.headline)

                    LazyVStack(spacing: 12) {
                        ForEach(batchResult.results) { result in
                            VStack(alignment: .leading, spacing: 8) {
                                // Task header
                                HStack {
                                    Text(result.description)
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                    Spacer()
                                    Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundStyle(result.success ? .green : .red)
                                }

                                // Stats
                                HStack(spacing: 16) {
                                    Label("^[\(result.turnCount) turn](inflect: true)", systemImage: "arrow.triangle.2.circlepath")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Label("^[\(result.toolCallCount) tool](inflect: true)", systemImage: "wrench.adjustable")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                // Tool calls
                                if !result.toolCalls.isEmpty {
                                    VStack(alignment: .leading, spacing: 6) {
                                        ForEach(result.toolCalls) { toolCall in
                                            HStack {
                                                Image(systemName: "chevron.right")
                                                    .font(.caption)
                                                    .foregroundStyle(.tertiary)
                                                Text(toolCall.toolName)
                                                    .font(.caption.monospaced())
                                                    .fontWeight(.medium)
                                                Text("• \(toolCall.summary)")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                Spacer()
                                            }
                                        }
                                    }
                                    .padding(.leading, 8)
                                }
                            }
                            .padding()
                            .background(Color.secondary.opacity(0.1), in: .rect(cornerRadius: 8))
                        }
                    }
                }
            }
        }
    }
}

struct FileToolExecutionDetailContent: View {
    var execution: ToolExecution
    @Environment(\.claudeClient) private var client
    @State private var filePath: FilePath?
    @State private var fileContents: String?

    var outputLabel: String {
        execution.name == "Read" ? "File Contents" : "Output"
    }

    var body: some View {
        Group {
            // Input summary (fallback when decodedInput is unavailable)
            if execution.decodedInput == nil && !execution.input.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Input")
                        .font(.headline)
                    Text(execution.input)
                        .font(.body)
                        .fontDesign(.monospaced)
                        .textSelection(.enabled)
                }
            }

            // File path
            if let filePath = filePath {
                VStack(alignment: .leading, spacing: 4) {
                    Text("File Path")
                        .font(.headline)
                    Text(filePath.string)
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
            guard let input = execution.decodedInput as? FileToolInput else { return }

            filePath = input.filePath

            do {
                let contents = try String(contentsOf: URL(filePath: input.filePath)!, encoding: .utf8)
                fileContents = contents
            } catch {
                fileContents = "Error reading file: \(error.localizedDescription)"
            }
        }
    }
}

struct FetchExecutionDetailContent: View {
    var execution: ToolExecution

    var decodedInput: FetchToolInput? {
        execution.decodedInput as? FetchToolInput
    }

    var decodedOutput: FetchToolOutput? {
        execution.decodedOutput as? FetchToolOutput
    }

    var body: some View {
        Group {
            // Input summary (fallback when decodedInput is unavailable)
            if decodedInput == nil && !execution.input.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Input")
                        .font(.headline)
                    Text(execution.input)
                        .font(.body)
                        .fontDesign(.monospaced)
                        .textSelection(.enabled)
                }
            }

            // URL
            if let url = decodedInput?.url {
                VStack(alignment: .leading, spacing: 4) {
                    Text("URL")
                        .font(.headline)
                    Text(url)
                        .font(.body)
                        .textSelection(.enabled)
                }
            }

            // Status & Size (if structured output available)
            if let output = decodedOutput {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Status")
                            .font(.headline)
                        Text("HTTP \(output.statusCode)")
                            .font(.body)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Size")
                            .font(.headline)
                        Text(output.size.formatted(.byteCount(style: .file)))
                            .font(.body)
                    }
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
                    let content = decodedOutput?.content ?? execution.output
                    Text(content.isEmpty ? "(no output)" : content)
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

struct GenericToolExecutionDetailContent: View {
    var execution: ToolExecution

    var body: some View {
        Group {
            // MCP Server metadata (if present)
            if let serverName = execution.metadata["server"] {
                VStack(alignment: .leading, spacing: 4) {
                    Text("MCP Server")
                        .font(.headline)
                    Text(serverName)
                        .font(.body)
                        .fontDesign(.monospaced)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

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
            .multilineTextAlignment(isSent ? .trailing : .leading)
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

    var filePath: FilePath? {
        guard let output = execution.decodedOutput as? WebCanvasOutput else {
            return nil
        }
        return output.filePath
    }

    var canvasPreview: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title bar
            HStack {
                Text("WebCanvas")
                    .font(.headline)
                    .fontDesign(.monospaced)
                Spacer()
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color.secondary.opacity(0.05))

            Divider()

            // Canvas preview
            if let filePath = filePath {
                WebView(url: URL(filePath: filePath)!)
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .frame(maxWidth: 600, maxHeight: 400)
                    .task {
                        // Parse aspect ratio from structured output
                        if let output = execution.decodedOutput as? WebCanvasOutput {
                            let components = output.aspectRatio.split(separator: ":").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
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
        .background(Color.secondary.opacity(0.1), in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(borderColor, style: StrokeStyle(lineWidth: 1 / displayScale))
        }
    }

    var body: some View {
        NavigationLink {
            WebCanvasFullScreenView(execution: execution)
        } label: {
            canvasPreview
        }
        .buttonStyle(.plain)
    }
}

struct WebCanvasFullScreenView: View {
    var execution: ToolExecution
    @Environment(\.dismiss) var dismiss

    var filePath: FilePath? {
        guard let output = execution.decodedOutput as? WebCanvasOutput else {
            return nil
        }
        return output.filePath
    }

    var body: some View {
        if let filePath = filePath {
            WebView(url: URL(filePath: filePath)!)
                .navigationTitle("WebCanvas")
                .toolbarTitleDisplayMode(.inlineLarge)
        } else {
            Text("Failed to load canvas")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Map Search View

struct MapSearchView: View {
    let execution: ToolExecution
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.displayScale) var displayScale
    @State private var showingFullScreen = false

    var borderColor: Color {
        colorScheme == .dark ? .darkBorder : .lightBorder
    }

    var results: [MapSearchResult]? {
        guard let output = execution.decodedOutput as? MapSearchToolOutput else {
            return nil
        }
        return output.results
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title bar
            HStack {
                Text("MapSearch")
                    .font(.headline)
                    .fontDesign(.monospaced)
                Spacer()
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color.secondary.opacity(0.05))
            .contentShape(Rectangle())
            .onTapGesture {
                showingFullScreen = true
            }

            Divider()

            // Map preview
            if let results = results, !results.isEmpty {
                MapSearchMapView(results: results)
                    .aspectRatio(6/4, contentMode: .fit)
                    .frame(maxWidth: 600, maxHeight: 400)
            } else {
                Text("No results to display")
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
        .background(Color.secondary.opacity(0.1), in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(borderColor, style: StrokeStyle(lineWidth: 1 / displayScale))
        }
        .sheet(isPresented: $showingFullScreen) {
            if let results = results {
                MapSearchFullScreenView(results: results)
            }
        }
    }
}

struct MapSearchMapView: View {
    let results: [MapSearchResult]
    @State private var region: MKCoordinateRegion

    init(results: [MapSearchResult]) {
        self.results = results

        // Calculate region that fits all results
        let coordinates = results.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }

        if let first = coordinates.first {
            var minLat = first.latitude
            var maxLat = first.latitude
            var minLon = first.longitude
            var maxLon = first.longitude

            for coord in coordinates {
                minLat = min(minLat, coord.latitude)
                maxLat = max(maxLat, coord.latitude)
                minLon = min(minLon, coord.longitude)
                maxLon = max(maxLon, coord.longitude)
            }

            let center = CLLocationCoordinate2D(
                latitude: (minLat + maxLat) / 2,
                longitude: (minLon + maxLon) / 2
            )

            let span = MKCoordinateSpan(
                latitudeDelta: (maxLat - minLat) * 1.5, // Add 50% padding
                longitudeDelta: (maxLon - minLon) * 1.5
            )

            _region = State(initialValue: MKCoordinateRegion(center: center, span: span))
        } else {
            _region = State(initialValue: MKCoordinateRegion())
        }
    }

    var body: some View {
        Map(position: .constant(.region(region))) {
            ForEach(results.indices, id: \.self) { index in
                let result = results[index]
                let coordinate = CLLocationCoordinate2D(latitude: result.latitude, longitude: result.longitude)

                Marker(result.name, coordinate: coordinate)
            }
        }
    }
}

struct MapSearchFullScreenView: View {
    let results: [MapSearchResult]
    @Environment(\.dismiss) var dismiss

    var body: some View {
        MapSearchMapView(results: results)
            .navigationTitle("Map Results")
            .toolbarTitleDisplayMode(.inlineLarge)
    }
}

// MARK: - File Tool Menu

struct FileToolMenu: View {
    let filePath: FilePath
    @State private var fileContents: String = ""
    @State private var isLoadingFile = false

    var body: some View {
        Menu {
            NavigationLink {
                FileViewerView(filePath: filePath)
            } label: {
                Label("View File", systemImage: "doc.text")
            }

            Button {
                #if os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(filePath.string, forType: .string)
                #else
                UIPasteboard.general.url = URL(filePath: filePath)
                #endif
            } label: {
                Label("Copy Path", systemImage: "doc.on.doc")
            }

            ShareLink(item: URL(filePath: filePath)!) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(Color.secondary.opacity(0.15), in: .circle)
        }
        .buttonStyle(.plain)
        .buttonBorderShape(.circle)
    }
}

// MARK: - File Viewer

struct FileViewerView: View {
    let filePath: FilePath
    @State private var fileContents: String = ""
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading file...")
            } else if let error = errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(error)
                        .foregroundStyle(.secondary)
                }
            } else {
                TextEditor(text: .constant(fileContents))
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .disabled(true)
            }
        }
        .navigationTitle(filePath.lastComponent?.string ?? "File")
        .task {
            await loadFile()
        }
    }

    private func loadFile() async {
        do {
            let contents = try String(contentsOf: URL(filePath: filePath)!, encoding: .utf8)
            fileContents = contents
            isLoading = false
        } catch {
            errorMessage = "Failed to load file: \(error.localizedDescription)"
            isLoading = false
        }
    }
}

// MARK: - WebView

#if canImport(UIKit)
import WebKit

struct WebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        WKWebView()
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // For file URLs, use loadFileURL with read access to the parent directory
        if url.isFileURL {
            let readAccessURL = url.deletingLastPathComponent()
            webView.loadFileURL(url, allowingReadAccessTo: readAccessURL)
        } else {
            webView.load(URLRequest(url: url))
        }
    }
}
#elseif canImport(AppKit)
import WebKit

struct WebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        WKWebView()
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // For file URLs, use loadFileURL with read access to the parent directory
        if url.isFileURL {
            let readAccessURL = url.deletingLastPathComponent()
            webView.loadFileURL(url, allowingReadAccessTo: readAccessURL)
        } else {
            webView.load(URLRequest(url: url))
        }
    }
}
#endif

// MARK: - File Attachment View

struct FileAttachmentView: View {
    let attachment: FileAttachment
    let messageKind: ConversationMessage.Kind
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.displayScale) var displayScale
    @Environment(\.uploadingFiles) var uploadingFiles
    @State private var showingFullScreen = false

    #if canImport(UIKit)
    @State private var loadedImage: UIImage?
    #elseif canImport(AppKit)
    @State private var loadedImage: NSImage?
    #endif

    var borderColor: Color {
        colorScheme == .dark ? .darkBorder : .lightBorder
    }

    var isImage: Bool {
        attachment.mimeType.hasPrefix("image/")
    }

    var iconName: String {
        if attachment.mimeType == "application/pdf" {
            return "doc.richtext"
        } else {
            return "doc"
        }
    }

    var maxWidth: CGFloat {
        messageKind == .user ? 300 : 400
    }

    var isUploading: Bool {
        uploadingFiles.contains(attachment.path.string)
    }

    @ViewBuilder
    private var imageView: some View {
        if let image = loadedImage {
            #if canImport(UIKit)
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
            #elseif canImport(AppKit)
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
            #endif
        }
    }

    var body: some View {
        Group {
            if isUploading {
                // Uploading spinner
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.1))
                    .frame(width: maxWidth, height: isImage ? 200 : 60)
                    .overlay {
                        VStack(spacing: 8) {
                            ProgressView()
                            Text("Uploading...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
            } else if isImage {
                if let image = loadedImage {
                    // Image preview
                    imageView
                        .frame(maxWidth: maxWidth)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(borderColor, style: StrokeStyle(lineWidth: 1 / displayScale))
                        }
                        .onTapGesture {
                            showingFullScreen = true
                        }
                        .sheet(isPresented: $showingFullScreen) {
                            ImageFullScreenView(image: image, fileName: attachment.fileName)
                        }
                } else {
                    // Loading placeholder
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.1))
                        .frame(width: maxWidth, height: 200)
                        .overlay {
                            VStack(spacing: 8) {
                                ProgressView()
                                Text("Loading image...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                }
            } else if !isImage {
                // Document icon
                HStack(spacing: 12) {
                    Image(systemName: iconName)
                        .font(.title2)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(attachment.fileName)
                            .font(.subheadline)
                            .lineLimit(1)

                        Text(formatFileSize(attachment.fileSize))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
                .padding(12)
                .frame(maxWidth: maxWidth)
                .background(Color.secondary.opacity(0.1), in: .rect(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(borderColor, style: StrokeStyle(lineWidth: 1 / displayScale))
                }
            }
        }
        .frame(maxWidth: messageKind == .user ? maxWidth : .infinity, alignment: messageKind == .user ? .trailing : .leading)
        .onAppear {
            if isImage {
                loadImage()
            }
        }
    }

    #if canImport(UIKit)
    private func loadImage() {
        print("🖼️ Loading image from: \(attachment.path.string)")
        print("🖼️ MIME type: \(attachment.mimeType)")
        print("🖼️ File size: \(attachment.fileSize)")

        let url = URL(filePath: attachment.path)!
        let fileExists = FileManager.default.fileExists(atPath: attachment.path.string)
        print("🖼️ File exists: \(fileExists)")

        guard let data = try? Data(contentsOf: url) else {
            print("❌ Failed to load data from file")
            return
        }
        print("🖼️ Loaded \(data.count) bytes")

        guard let image = UIImage(data: data) else {
            print("❌ Failed to create UIImage from data")
            return
        }
        print("✅ Successfully loaded image: \(image.size)")
        loadedImage = image
    }
    #elseif canImport(AppKit)
    private func loadImage() {
        print("🖼️ Loading image from: \(attachment.path.string)")
        print("🖼️ MIME type: \(attachment.mimeType)")
        print("🖼️ File size: \(attachment.fileSize)")

        let url = URL(filePath: attachment.path)!
        let fileExists = FileManager.default.fileExists(atPath: attachment.path.string)
        print("🖼️ File exists: \(fileExists)")

        guard let data = try? Data(contentsOf: url) else {
            print("❌ Failed to load data from file")
            return
        }
        print("🖼️ Loaded \(data.count) bytes")

        guard let image = NSImage(data: data) else {
            print("❌ Failed to create NSImage from data")
            return
        }
        print("✅ Successfully loaded image: \(image.size)")
        loadedImage = image
    }
    #endif

    private func formatFileSize(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

#if canImport(UIKit)
struct ImageFullScreenView: View {
    let image: UIImage
    let fileName: String
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .navigationTitle(fileName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
        }
    }
}
#elseif canImport(AppKit)
struct ImageFullScreenView: View {
    let image: NSImage
    let fileName: String
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .navigationTitle(fileName)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
        }
    }
}
#endif
