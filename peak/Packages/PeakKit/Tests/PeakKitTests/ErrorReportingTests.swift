import Foundation
import Testing
@testable import PeakKit

@Suite("Error reports")
struct ErrorReportingTests {
    let now = Fixtures.now

    func count(_ message: String, _ source: String = "server", version: Int?, _ n: Int, ago hours: Double = 1) -> ErrorCount {
        ErrorCount(signature: ErrorClusterer.signature(message), example: ErrorClusterer.redacted(message), source: source,
                   placeVersion: version, count: n, firstSeen: now.addingTimeInterval(-hours * 3_600),
                   lastSeen: now.addingTimeInterval(-hours * 1_800))
    }

    @Test func redactionKeepsLineNumbersButNotPeopleOrValues() {
        #expect(ErrorClusterer.redacted("ServerScriptService.Pets:42: attempt to index nil with 'Level' (Players.Alice.Backpack)")
            == "ServerScriptService.Pets:42: attempt to index nil with '…' (Players.<player>.Backpack)")
        #expect(ErrorClusterer.redacted("Workspace.Shop:7: not enough coins: 250 for user 1234567")
            == "Workspace.Shop:7: not enough coins: # for user #")
        #expect(ErrorClusterer.redacted("Script:12 failed after 3.5s") == "Script:# failed after #s")
    }

    @Test func storedCountsGroupAcrossDaysVersionsAndSources() throws {
        let counts = [
            count("ServerScriptService.Pets:42: attempt to index nil (Players.Alice.Backpack)", version: 128, 30, ago: 2),
            count("ServerScriptService.Pets:57: attempt to index nil (Players.Bob.Backpack)", "client", version: 128, 10, ago: 30),
            count("DataStore request dropped", version: 127, 40, ago: 100),
            count("DataStore request dropped", version: 128, 20),
            count("ignored", version: 128, 0),
        ]
        let clusters = ErrorClusterer.cluster(counts: counts)
        #expect(clusters.map(\.count) == [60, 40])
        let datastore = clusters[0]
        #expect(datastore.versions == [127, 128])
        #expect(datastore.isNewInLatestVersion == false)
        #expect(datastore.share == 0.6)
        #expect(datastore.firstSeen == now.addingTimeInterval(-100 * 3_600))
        #expect(datastore.lastSeen == now.addingTimeInterval(-1_800))

        let pets = clusters[1]
        #expect(pets.isNewInLatestVersion)
        #expect(pets.sources == ["client", "server"])
        #expect(pets.example == "ServerScriptService.Pets:42: attempt to index nil (Players.<player>.Backpack)", "the newest example")
        #expect(pets.summary == "Happened 40 times (40% of reported errors), on the server and on players' devices. "
            + "Only seen in v128, so the latest update is a possible cause.")
        let location = try #require(pets.location)
        #expect(location.script == "ServerScriptService.Pets" && location.line == 42)
    }

    @Test func nothingNewWithoutAnOlderVersionAndEmptyInput() {
        #expect(ErrorClusterer.cluster(counts: []).isEmpty)
        #expect(ErrorClusterer.cluster(counts: [count("x", version: 5, 0)]).isEmpty)
        let single = ErrorClusterer.cluster(counts: [count("only one version", version: 9, 1)])
        #expect(single.first?.isNewInLatestVersion == false)
        #expect(single.first?.summary == "Happened 1 time (100% of reported errors), on the server.")
        #expect(single.first?.location == nil)
    }

    @Test func promptPointsAtTheLineAndLabelsTheUpdateAsPossible() throws {
        let cluster = try #require(SampleData.errorClusters(gameID: SampleData.attackAnimalsID, now: now).first)
        let text = ClaudePromptGenerator.render(ClaudePromptGenerator.prompt(for: cluster, gameName: "Attack Animals"))
        #expect(text.contains("Open ServerScriptService.Pets at line 42"))
        #expect(text.contains("Possible causes (not confirmed"))
        #expect(text.contains("v128"))
        #expect(text.contains("Alice") == false)
    }

    @Test func sampleClustersAreRedacted() {
        let clusters = SampleData.errorClusters(gameID: SampleData.attackAnimalsID, now: now)
        #expect(clusters.count == 3)
        #expect(clusters.allSatisfy { $0.example.contains("Alice") == false && $0.example.contains("bob_99") == false })
        #expect(clusters.first { $0.sources == ["client"] } != nil)
        #expect(SampleData.errorClusters(gameID: 1, now: now).isEmpty)
    }

    @Test func endpointsAndBodies() throws {
        #expect(BackendAPI.createErrorKey(gameID: 7).method == .post)
        #expect(BackendAPI.createErrorKey(gameID: 7).path == "v1/games/7/error-key")
        #expect(BackendAPI.errors(gameID: 7).path == "v1/games/7/errors")
        // The exact JSON the Luau server script sends.
        let body = #"{"placeVersion":128,"errors":[{"message":"boom","source":"client","count":3}]}"#
        let decoded = try JSONDecoder().decode(BackendAPI.IngestErrors.self, from: Data(body.utf8))
        #expect(decoded == BackendAPI.IngestErrors(placeVersion: 128, errors: [.init(message: "boom", count: 3, source: "client")]))
    }

    @Test func serverScriptGetsTheEndpoint() {
        let script = ErrorReporterScripts.server(endpoint: URL(string: "https://peak.example.com/v1/ingest/errors"))
        #expect(script.contains(#"local ENDPOINT = "https://peak.example.com/v1/ingest/errors""#))
        #expect(script.contains(ErrorReporterScripts.endpointPlaceholder) == false)
        #expect(ErrorReporterScripts.server(endpoint: nil) == ErrorReporterScripts.serverTemplate)
        #expect(ErrorReporterScripts.serverTemplate.contains(#"GetSecret("\#(ErrorReporterScripts.secretName)")"#))
        // No secret material ever goes in the client script.
        #expect(ErrorReporterScripts.client.contains("GetSecret") == false)
    }

    static let robloxFolder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Roblox")

    /// The app shows the same scripts the repo ships. Skipped when only the package is checked out.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: robloxFolder.path)))
    func shippedScriptsMatchTheApp() throws {
        let server = try String(contentsOf: Self.robloxFolder.appendingPathComponent("PeakErrorReporter.server.luau"), encoding: .utf8)
        let client = try String(contentsOf: Self.robloxFolder.appendingPathComponent("PeakErrorReporter.client.luau"), encoding: .utf8)
        #expect(server == ErrorReporterScripts.serverTemplate + "\n")
        #expect(client == ErrorReporterScripts.client + "\n")
    }
}
