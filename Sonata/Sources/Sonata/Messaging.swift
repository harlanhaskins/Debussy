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

                case .toolExecution(let execution):
                    if execution.name == "WebCanvas", execution.isComplete, !execution.isError {
                        WebCanvasView(execution: execution)
                    } else if execution.name == "MapSearch", execution.isComplete, !execution.isError, execution.decodedOutput != nil {
                        MapSearchView(execution: execution)
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

    var decodedInput: JavaScriptToolInput? {
        execution.decodedInput as? JavaScriptToolInput
    }

    var body: some View {
        Group {
            // Code section
            if let code = decodedInput?.code {
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
    }
}

struct FileToolExecutionDetailContent: View {
    var execution: ToolExecution
    @Environment(\.claudeClient) private var client
    @State private var filePath: String?
    @State private var fileContents: String?

    var outputLabel: String {
        execution.name == "Read" ? "File Contents" : "Output"
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
            guard let input = execution.decodedInput as? FileToolInput else { return }

            filePath = input.filePath

            do {
                let contents = try String(contentsOfFile: input.filePath, encoding: .utf8)
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

    var body: some View {
        Group {
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
    @State private var showingFullScreen = false

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
            .contentShape(Rectangle())
            .onTapGesture {
                showingFullScreen = true
            }

            Divider()

            // Canvas preview
            if let path = filePath {
                let url = URL(filePath: path)
                WebView(url: url)
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .frame(maxWidth: 600, maxHeight: 400)
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
        .background(Color.secondary.opacity(0.1), in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(borderColor, style: StrokeStyle(lineWidth: 1 / displayScale))
        }
        .sheet(isPresented: $showingFullScreen) {
            WebCanvasFullScreenView(execution: execution, aspectRatio: aspectRatio)
        }
    }
}

struct WebCanvasFullScreenView: View {
    var execution: ToolExecution
    var aspectRatio: CGFloat
    @Environment(\.dismiss) var dismiss

    var filePath: String? {
        guard let line = execution.output.split(separator: "\n").first,
              let pathStart = line.range(of: "Created canvas at ")?.upperBound else {
            return nil
        }
        return String(line[pathStart...])
    }

    var body: some View {
        NavigationStack {
            if let path = filePath {
                let url = URL(filePath: path)
                WebView(url: url)
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .navigationTitle("WebCanvas")
                    .toolbarTitleDisplayMode(.inlineLarge)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                dismiss()
                            }
                        }
                    }
            } else {
                Text("Failed to load canvas")
                    .foregroundStyle(.secondary)
            }
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
        NavigationStack {
            MapSearchMapView(results: results)
                .navigationTitle("Map Results")
                .toolbarTitleDisplayMode(.inlineLarge)
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
