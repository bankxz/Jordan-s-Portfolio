import Foundation
import Testing
@testable import PeakKit

struct RouteTests {
    static let goalID = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!

    static let roundTrips: [Route] = [
        .home, .games, .game(id: 1), .game(id: Int64.max), .goals, .goal(id: goalID),
        .alerts, .campaign(id: "spring_launch-2"), .authComplete(code: "abc.DEF-123_~"),
        .authComplete(code: "has space&amp=1"),
    ]

    @Test(arguments: roundTrips)
    func roundTrip(route: Route) {
        #expect(Route(url: route.url) == route)
    }

    @Test(arguments: [
        ("peakstats://game/920587237", Route.game(id: 920_587_237)),
        ("PEAKSTATS://GAME/5", .game(id: 5)),
        ("peakstats://home", .home),
        ("peakstats://home/", .home),
        ("peakstats://auth/complete?code=xyz&other=1", .authComplete(code: "xyz")),
    ])
    func parsesValid(string: String, expected: Route) throws {
        let url = try #require(URL(string: string))
        #expect(Route(url: url) == expected)
    }

    @Test(arguments: [
        "https://game/5",                       // wrong scheme
        "peakstats://game",                      // missing id
        "peakstats://game/0",                    // non-positive
        "peakstats://game/-4",
        "peakstats://game/+4",
        "peakstats://game/abc",
        "peakstats://game/99999999999999999999", // overflow
        "peakstats://game/5/extra",
        "peakstats://goal/not-a-uuid",
        "peakstats://campaign/has.dot",
        "peakstats://campaign/" + String(repeating: "a", count: 65),
        "peakstats://auth/complete",             // no code
        "peakstats://auth/complete?code=",       // empty code
        "peakstats://auth/complete?code=a&code=b", // ambiguous
        "peakstats://auth/other?code=a",
        "peakstats://settings",                  // unknown host
        "peakstats:///game/5",                   // no host
    ])
    func rejectsInvalid(string: String) throws {
        let url = try #require(URL(string: string))
        #expect(Route(url: url) == nil)
    }

    @Test func rejectsOversizedAuthCode() throws {
        let url = Route.authComplete(code: String(repeating: "x", count: 513)).url
        #expect(Route(url: url) == nil)
    }
}
