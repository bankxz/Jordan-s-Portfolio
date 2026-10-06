import PeakKit
import SwiftUI
import UniformTypeIdentifiers

/// Imports an Ads Manager CSV. The file is parsed on the phone first so the creator sees exactly what will be
/// imported (and which columns were missing) before anything is uploaded.
struct CampaignImportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var gameID: Int64?
    @State private var isPickingFile = false
    @State private var csv: String?
    @State private var preview: Result<CampaignImport.Result, CampaignImport.Failure>?
    @State private var isUploading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Game", selection: $gameID) {
                        ForEach(model.dashboard?.games ?? []) { game in
                            Text(game.name).tag(Optional(game.id))
                        }
                    }
                    Button("Choose CSV file", systemImage: "doc") { isPickingFile = true }
                } footer: {
                    Text("In Roblox Ads Manager, open your campaigns and download the report as CSV. It needs campaign name, impressions and spend columns; clicks and plays are used when present.")
                }

                if let preview { previewSection(preview) }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.orange) }
                }
            }
            .navigationTitle("Import ad results")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { Task { await upload() } }
                        .disabled(canUpload == false)
                }
            }
            .fileImporter(isPresented: $isPickingFile, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
                load(result)
            }
            .onAppear { if gameID == nil { gameID = model.dashboard?.games.first?.id } }
            .onChange(of: gameID) { reparse() }
        }
    }

    @ViewBuilder
    private func previewSection(_ preview: Result<CampaignImport.Result, CampaignImport.Failure>) -> some View {
        switch preview {
        case .success(let result):
            Section("Preview") {
                ForEach(result.campaigns) { campaign in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(campaign.name).font(.subheadline.weight(.semibold))
                        Text("\(MetricFormatter.robux(campaign.spentRobux)) spent · \(MetricFormatter.compact(campaign.impressions)) impressions · \(MetricFormatter.compact(campaign.plays)) plays")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if result.skippedRows > 0 {
                    Text("\(result.skippedRows) rows skipped (totals or missing numbers).")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        case .failure(let failure):
            Section {
                Label(Self.describe(failure), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
    }

    private var canUpload: Bool {
        guard gameID != nil, isUploading == false, case .success(let result)? = preview else { return false }
        return result.campaigns.isEmpty == false
    }

    private func load(_ result: Result<URL, Error>) {
        errorMessage = nil
        guard case .success(let url) = result else {
            errorMessage = "Couldn't open that file."
            return
        }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), data.count <= CampaignImport.maxBytes,
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            errorMessage = "That file is too large or isn't a CSV."
            return
        }
        csv = text
        reparse()
    }

    private func reparse() {
        guard let csv, let gameID else { return }
        do {
            preview = .success(try CampaignImport.parse(csv: csv, gameID: gameID))
        } catch let failure as CampaignImport.Failure {
            preview = .failure(failure)
        } catch {
            preview = nil
        }
    }

    private func upload() async {
        guard let csv, let gameID else { return }
        isUploading = true
        defer { isUploading = false }
        do {
            _ = try await model.importCampaigns(csv: csv, gameID: gameID)
            dismiss()
        } catch {
            errorMessage = AppModel.message(for: error)
        }
    }

    static func describe(_ failure: CampaignImport.Failure) -> String {
        switch failure {
        case .empty: "The file has no rows."
        case .tooLarge: "The file is too large (1 MB maximum)."
        case .missingColumns(let columns):
            "Couldn't find these columns: " + columns.map(\.rawValue).joined(separator: ", ") + ". Check the export includes them."
        }
    }
}
