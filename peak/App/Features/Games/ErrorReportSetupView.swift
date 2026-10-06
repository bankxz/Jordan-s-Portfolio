import PeakKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Which game the error-report setup sheet is for (`.sheet(item:)`).
struct ErrorReportTarget: Identifiable, Hashable {
    let gameID: Int64
    let gameName: String

    var id: Int64 { gameID }
}

/// Walks the creator through installing Peak's error reporter (decision 0008): HTTP requests on, a key from
/// Peak stored as a Roblox Secret, and two scripts. Nothing changes in the game until the creator does it.
struct ErrorReportSetupView: View {
    let target: ErrorReportTarget

    @Environment(InsightsModel.self) private var insights
    @Environment(\.dismiss) private var dismiss
    @State private var setup: InsightsModel.Load<BackendAPI.ErrorReportSetup> = .idle
    @State private var copied: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("In Studio, open Game Settings > Security and turn on Allow HTTP Requests.")
                } header: {
                    Text("1. Allow HTTP requests")
                }

                keySection
                secretSection
                scriptsSection

                Section {
                    Label("Player names and IDs are removed in your game and again on Peak's server. Peak keeps only grouped counts, for 30 days.",
                          systemImage: "lock.shield")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Error reports")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sensoryFeedback(.success, trigger: copied)
        }
    }

    private var setupValue: BackendAPI.ErrorReportSetup? { setup.value }

    @ViewBuilder
    private var keySection: some View {
        Section {
            switch setup {
            case .idle, .failed:
                Button("Create key for \(target.gameName)", systemImage: "key") {
                    Task {
                        setup = .loading
                        setup = await insights.createErrorKey(gameID: target.gameID)
                    }
                }
                .accessibilityIdentifier("createErrorKeyButton")
                if case .failed(let message) = setup {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            case .loading:
                ProgressView()
            case .loaded(let value):
                Text(value.key)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .accessibilityIdentifier("errorKeyText")
                copyButton("Copy key", value: value.key, secret: true)
            }
        } header: {
            Text("2. Get a key")
        } footer: {
            Text("The key is shown only once. Creating a new key stops the old one, so the game must be given the new key.")
        }
    }

    private var secretSection: some View {
        Section {
            LabeledContent("Name", value: ErrorReporterScripts.secretName)
            LabeledContent("Value", value: "The key from step 2")
            if let host = setupValue?.endpoint.host() {
                LabeledContent("Domain", value: host)
                copyButton("Copy domain", value: host)
            }
        } header: {
            Text("3. Add it as a secret")
        } footer: {
            Text("In Creator Hub, open your game > Secrets and add a secret with these details. Roblox only sends it to that domain, and only from game servers.")
        }
    }

    private var scriptsSection: some View {
        let server = ErrorReporterScripts.server(endpoint: setupValue?.endpoint)
        return Section {
            copyButton("Copy server script", value: server)
            ShareLink(item: server, preview: SharePreview("PeakErrorReporter (server)")) {
                Label("Share server script", systemImage: "square.and.arrow.up")
            }
            copyButton("Copy client script", value: ErrorReporterScripts.client)
            ShareLink(item: ErrorReporterScripts.client, preview: SharePreview("PeakErrorReporter (client)")) {
                Label("Share client script", systemImage: "square.and.arrow.up")
            }
        } header: {
            Text("4. Add the scripts")
        } footer: {
            Text("Put the server script in a Script in ServerScriptService and the client script in a LocalScript in StarterPlayerScripts, then publish. Errors appear here within a few minutes.")
        }
    }

    private func copyButton(_ title: String, value: String, secret: Bool = false) -> some View {
        Button {
            if secret {
                // Kept off other devices (Universal Clipboard) and cleared after 10 minutes.
                UIPasteboard.general.setItems([[UTType.plainText.identifier: value]],
                                              options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(600)])
            } else {
                UIPasteboard.general.string = value
            }
            copied = title
        } label: {
            Label(copied == title ? "Copied" : title, systemImage: copied == title ? "checkmark" : "doc.on.doc")
        }
    }
}
