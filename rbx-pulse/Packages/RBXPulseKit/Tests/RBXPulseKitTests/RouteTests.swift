import Foundation
import Testing
@testable import RBXPulseKit

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
        ("rbxpulse://game/920587237", Route.game(id: 920_587_237)),
        ("RBXPULSE://GAME/5", .game(id: 5)),
        ("rbxpulse://home", .home),
        ("rbxpulse://home/", .home),
        ("rbxpulse://auth/complete?code=xyz&other=1", .authComplete(code: "xyz")),
    ])
    func parsesValid(string: String, expected: Route) throws {
        let url = try #require(URL(string: string))
        #expect(Route(url: url) == expected)
    }

    @Test(arguments: [
        "https://game/5",                       // wrong scheme
        "rbxpulse://game",                      // missing id
        "rbxpulse://game/0",                    // non-positive
        "rbxpulse://game/-4",
        "rbxpulse://game/+4",
        "rbxpulse://game/abc",
        "rbxpulse://game/99999999999999999999", // overflow
        "rbxpulse://game/5/extra",
        "rbxpulse://goal/not-a-uuid",
        "rbxpulse://campaign/has.dot",
        "rbxpulse://campaign/" + String(repeating: "a", count: 65),
        "rbxpulse://auth/complete",             // no code
        "rbxpulse://auth/complete?code=",       // empty code
        "rbxpulse://auth/complete?code=a&code=b", // ambiguous
        "rbxpulse://auth/other?code=a",
        "rbxpulse://settings",                  // unknown host
        "rbxpulse:///game/5",                   // no host
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
