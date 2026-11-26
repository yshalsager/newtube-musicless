import Testing
@testable import YouTubeEngine

/// US-015: Android's `PhoneSourcePlannerTest` (MediaServiceCore `52fecea0`), ported. The expected
/// orders are Android's strings verbatim; `android(_:)` drops MWEB, WEB and WEB_SAFARI, which iOS
/// doesn't ask (PRD §4.4), so each line can be compared with the Java test by eye.
@Suite struct SourcePlannerTests {
    typealias C = ClientProfile

    static func android(_ order: String) -> String {
        order.split(separator: " ").filter { !["MWEB", "WEB", "WEB_SAFARI"].contains($0) }.joined(separator: " ")
    }

    static func join(_ order: [ClientProfile]) -> String { order.map(\.id).joined(separator: " ") }

    static func plan(_ lane: Lane, _ suspect: ClientProfile? = nil, anonChallenged: Bool = false, benched: Bool = false,
                     configure: (inout SourcePlanner.Context) -> Void = { _ in }) -> String {
        var context = SourcePlanner.Context(lane: lane, recoverySuspect: suspect)
        context.anonChallenged = anonChallenged
        context.accountRouteBenched = benched
        configure(&context)
        return join(SourcePlanner.order(context))
    }

    @Test func theTwoLanes() {
        #expect(Self.plan(.signedOut) == Self.android("VISIONOS WEB_EMBED ANDROID_VR IOS ANDROID_REEL MWEB WEB WEB_SAFARI"))
        #expect(Self.plan(.signedIn) == Self.android("VISIONOS TV_TIZEN WEB_EMBED ANDROID_VR IOS ANDROID_REEL MWEB WEB WEB_SAFARI"))
    }

    @Test func recoveryAsksTheSuspectLast() {
        #expect(Self.plan(.signedOut, .visionOS) == Self.android("WEB_EMBED ANDROID_VR IOS ANDROID_REEL MWEB WEB WEB_SAFARI VISIONOS"))
        #expect(Self.plan(.signedIn, .visionOS) == Self.android("TV_TIZEN WEB_EMBED ANDROID_VR IOS ANDROID_REEL MWEB WEB WEB_SAFARI VISIONOS"))
        #expect(Self.plan(.signedIn, .tvTizen) == Self.android("VISIONOS WEB_EMBED ANDROID_VR IOS ANDROID_REEL MWEB WEB WEB_SAFARI TV_TIZEN"))
        // Signed out, a TV_TIZEN suspect (admitted by a refusal) is asked last; benched, it stays out.
        #expect(Self.plan(.signedOut, .tvTizen) == Self.android("VISIONOS WEB_EMBED ANDROID_VR IOS ANDROID_REEL MWEB WEB WEB_SAFARI TV_TIZEN"))
        #expect(!Self.plan(.signedOut, .tvTizen, benched: true).contains("TV_TIZEN"))
    }

    @Test func theAccountRouteFirstSwitch() {
        #expect(Self.plan(.signedIn) { $0.accountRouteFirst = true }
                == Self.android("TV_TIZEN VISIONOS WEB_EMBED ANDROID_VR IOS ANDROID_REEL MWEB WEB WEB_SAFARI"))
        #expect(Self.plan(.signedIn, .tvTizen) { $0.accountRouteFirst = true }
                == Self.android("VISIONOS WEB_EMBED ANDROID_VR IOS ANDROID_REEL MWEB WEB WEB_SAFARI TV_TIZEN"))
        #expect(Self.plan(.signedIn, benched: true) { $0.accountRouteFirst = true }
                == Self.android("VISIONOS WEB_EMBED ANDROID_VR IOS ANDROID_REEL MWEB WEB WEB_SAFARI"))
        #expect(Self.plan(.signedOut) { $0.accountRouteFirst = true }
                == Self.android("VISIONOS WEB_EMBED ANDROID_VR IOS ANDROID_REEL MWEB WEB WEB_SAFARI"))
    }

    @Test func aChallengedWebIdentityGoesLastButTheSuspectStaysLastest() {
        #expect(Self.plan(.signedOut, anonChallenged: true) == Self.android("VISIONOS ANDROID_VR IOS ANDROID_REEL WEB_EMBED MWEB WEB WEB_SAFARI"))
        #expect(Self.plan(.signedIn, anonChallenged: true) == Self.android("VISIONOS TV_TIZEN ANDROID_VR IOS ANDROID_REEL WEB_EMBED MWEB WEB WEB_SAFARI"))
        #expect(Self.plan(.signedOut, .androidVR, anonChallenged: true) == Self.android("VISIONOS IOS ANDROID_REEL WEB_EMBED MWEB WEB WEB_SAFARI ANDROID_VR"))
    }

    @Test func theAccountRouteIsAdmittedAfterAContentRefusalSignedOutOnly() {
        #expect(SourcePlanner.admitsAccountRouteAfter(lane: .signedOut, client: .visionOS))
        #expect(SourcePlanner.admitsAccountRouteAfter(lane: .signedOut, client: .androidVR))
        #expect(!SourcePlanner.admitsAccountRouteAfter(lane: .signedOut, client: .webEmbed))
        #expect(!SourcePlanner.admitsAccountRouteAfter(lane: .signedOut, client: .tvTizen))
        #expect(!SourcePlanner.admitsAccountRouteAfter(lane: .signedIn, client: .visionOS))
    }

    @Test func aRecoveryAsksWhatJustRefusedTheVideoLast() {
        func recovering(_ lane: Lane, _ suspect: ClientProfile?, benched: Bool, _ refused: Set<ClientProfile>) -> String {
            Self.plan(lane, suspect, benched: benched) { $0.recoveryRefused = refused }
        }
        #expect(recovering(.signedOut, .tvTizen, benched: false, [.visionOS])
                == Self.android("WEB_EMBED ANDROID_VR IOS ANDROID_REEL MWEB WEB WEB_SAFARI TV_TIZEN VISIONOS"))
        #expect(recovering(.signedIn, .tvTizen, benched: true, [.visionOS])
                == Self.android("WEB_EMBED ANDROID_VR IOS ANDROID_REEL MWEB WEB WEB_SAFARI VISIONOS"))
        #expect(recovering(.signedOut, .webEmbed, benched: false, [.androidVR, .visionOS])
                == Self.android("IOS ANDROID_REEL MWEB WEB WEB_SAFARI WEB_EMBED VISIONOS ANDROID_VR"))
        #expect(recovering(.signedOut, .visionOS, benched: false, [.visionOS])
                == Self.android("WEB_EMBED ANDROID_VR IOS ANDROID_REEL MWEB WEB WEB_SAFARI VISIONOS"))
        #expect(recovering(.signedOut, nil, benched: false, [.visionOS])
                == Self.android("VISIONOS WEB_EMBED ANDROID_VR IOS ANDROID_REEL MWEB WEB WEB_SAFARI"))
        #expect(recovering(.signedOut, .tvTizen, benched: false, [])
                == Self.android("VISIONOS WEB_EMBED ANDROID_VR IOS ANDROID_REEL MWEB WEB WEB_SAFARI TV_TIZEN"))
        #expect(recovering(.signedOut, .webEmbed, benched: false, [.visionOS, .tvTizen])
                == Self.android("ANDROID_VR IOS ANDROID_REEL MWEB WEB WEB_SAFARI WEB_EMBED VISIONOS TV_TIZEN"))
        #expect(recovering(.signedOut, .webEmbed, benched: true, [.visionOS, .tvTizen])
                == Self.android("ANDROID_VR IOS ANDROID_REEL MWEB WEB WEB_SAFARI WEB_EMBED VISIONOS"))
        #expect(recovering(.signedIn, .webEmbed, benched: false, [.visionOS, .tvTizen])
                == Self.android("ANDROID_VR IOS ANDROID_REEL MWEB WEB WEB_SAFARI WEB_EMBED VISIONOS TV_TIZEN"))
    }

    @Test func aKidsRecoveryAsksOnlyWhatServesKidsFirst() {
        func kids(_ lane: Lane, _ suspect: ClientProfile?, benched: Bool, _ refused: Set<ClientProfile>) -> String {
            Self.plan(lane, suspect, benched: benched) {
                $0.recoveryRefused = refused
                $0.recoveryKidsRefused = true
            }
        }
        #expect(kids(.signedOut, .webEmbed, benched: true, [.visionOS]) == Self.android("WEB_EMBED ANDROID_VR IOS ANDROID_REEL MWEB WEB WEB_SAFARI VISIONOS"))
        #expect(kids(.signedIn, .webEmbed, benched: true, [.visionOS]) == Self.android("WEB_EMBED ANDROID_VR IOS ANDROID_REEL MWEB WEB WEB_SAFARI VISIONOS"))
        #expect(kids(.signedOut, .tvTizen, benched: false, [.visionOS]) == Self.android("WEB_EMBED TV_TIZEN ANDROID_VR IOS ANDROID_REEL MWEB WEB WEB_SAFARI VISIONOS"))
        #expect(kids(.signedIn, .webEmbed, benched: false, [.visionOS]) == Self.android("TV_TIZEN WEB_EMBED ANDROID_VR IOS ANDROID_REEL MWEB WEB WEB_SAFARI VISIONOS"))
        #expect(kids(.signedOut, .webEmbed, benched: true, [.androidVR]) == Self.android("WEB_EMBED VISIONOS IOS ANDROID_REEL MWEB WEB WEB_SAFARI ANDROID_VR"))
        #expect(kids(.signedOut, nil, benched: false, []) == Self.android("VISIONOS WEB_EMBED ANDROID_VR IOS ANDROID_REEL MWEB WEB WEB_SAFARI"))
    }

    @Test func aKidsChannelHintLeadsWithTheAccountRouteUnlessBenchedOrRecovering() {
        #expect(Self.plan(.signedOut) { $0.accountRouteHinted = true }
                == Self.android("TV_TIZEN VISIONOS WEB_EMBED ANDROID_VR IOS ANDROID_REEL MWEB WEB WEB_SAFARI"))
        #expect(Self.plan(.signedOut, benched: true) { $0.accountRouteHinted = true }
                == Self.android("VISIONOS WEB_EMBED ANDROID_VR IOS ANDROID_REEL MWEB WEB WEB_SAFARI"))
        #expect(Self.plan(.signedOut, .visionOS) { $0.accountRouteHinted = true }
                == Self.android("WEB_EMBED ANDROID_VR IOS ANDROID_REEL MWEB WEB WEB_SAFARI VISIONOS"))
    }

    @Test func aLiveCardAsksTheLiveSourceFirst() {
        #expect(Self.plan(.signedOut) { $0.liveCardHinted = true } == Self.android("ANDROID_VR VISIONOS WEB_EMBED IOS ANDROID_REEL MWEB WEB WEB_SAFARI"))
        #expect(Self.plan(.signedIn) { $0.liveCardHinted = true } == Self.android("ANDROID_VR VISIONOS TV_TIZEN WEB_EMBED IOS ANDROID_REEL MWEB WEB WEB_SAFARI"))
        #expect(Self.plan(.signedOut, .visionOS) { $0.liveCardHinted = true } == Self.android("WEB_EMBED ANDROID_VR IOS ANDROID_REEL MWEB WEB WEB_SAFARI VISIONOS"))
        #expect(SourcePlanner.isPastLiveSourceTurn(.iOS) && SourcePlanner.isPastLiveSourceTurn(.androidReel))
        for client in [C.visionOS, .tvTizen, .webEmbed, .androidVR] { #expect(!SourcePlanner.isPastLiveSourceTurn(client)) }
    }

    @Test func vodVrLateMovesAndroidVrBehindTheWallSurvivors() {
        func vrLate(_ lane: Lane, _ suspect: ClientProfile?, benched: Bool, kids: Bool, _ refused: Set<ClientProfile>, live: Bool) -> String {
            Self.plan(lane, suspect, benched: benched) {
                $0.vodVrLate = true
                $0.recoveryKidsRefused = kids
                $0.recoveryRefused = refused
                $0.liveCardHinted = live
            }
        }
        #expect(vrLate(.signedOut, nil, benched: false, kids: false, [], live: false)
                == Self.android("VISIONOS WEB_EMBED TV_TIZEN ANDROID_REEL ANDROID_VR IOS MWEB WEB WEB_SAFARI"))
        #expect(vrLate(.signedOut, nil, benched: true, kids: false, [], live: false)
                == Self.android("VISIONOS WEB_EMBED ANDROID_REEL ANDROID_VR IOS MWEB WEB WEB_SAFARI"))
        #expect(vrLate(.signedIn, nil, benched: false, kids: false, [], live: false)
                == Self.android("VISIONOS TV_TIZEN WEB_EMBED ANDROID_REEL ANDROID_VR IOS MWEB WEB WEB_SAFARI"))
        #expect(vrLate(.signedOut, .visionOS, benched: false, kids: false, [], live: false)
                == Self.android("WEB_EMBED TV_TIZEN ANDROID_REEL ANDROID_VR IOS MWEB WEB WEB_SAFARI VISIONOS"))
        #expect(vrLate(.signedOut, .webEmbed, benched: true, kids: true, [.visionOS], live: false)
                == Self.android("WEB_EMBED ANDROID_REEL ANDROID_VR IOS MWEB WEB WEB_SAFARI VISIONOS"))
        #expect(vrLate(.signedOut, nil, benched: false, kids: false, [], live: true)
                == Self.android("ANDROID_VR VISIONOS WEB_EMBED IOS ANDROID_REEL MWEB WEB WEB_SAFARI"))
    }

    @Test func walledSourcesGoLastAndReRolledOnesComeBackBeforeReel() {
        func walls(_ suspect: ClientProfile?, _ refused: Set<ClientProfile>, _ benched: Set<ClientProfile>,
                   _ refreshed: Set<ClientProfile>, live: Bool) -> String {
            Self.plan(.signedOut, suspect) {
                $0.recoveryRefused = refused
                $0.vodVrLate = true
                $0.benched = benched
                $0.refreshed = refreshed
                $0.liveCardHinted = live
            }
        }
        let walled: Set<ClientProfile> = [.visionOS, .androidVR]
        #expect(walls(nil, [], walled, [], live: false) == Self.android("WEB_EMBED TV_TIZEN ANDROID_REEL IOS MWEB WEB WEB_SAFARI VISIONOS ANDROID_VR"))
        #expect(walls(.tvTizen, [.webEmbed], walled, [], live: false)
                == Self.android("ANDROID_REEL IOS MWEB WEB WEB_SAFARI TV_TIZEN WEB_EMBED VISIONOS ANDROID_VR"))
        #expect(walls(nil, [], walled, [], live: true) == Self.android("ANDROID_VR WEB_EMBED IOS ANDROID_REEL MWEB WEB WEB_SAFARI VISIONOS"))
        #expect(walls(.visionOS, [], [], [.visionOS], live: false)
                == Self.android("WEB_EMBED TV_TIZEN VISIONOS ANDROID_REEL ANDROID_VR IOS MWEB WEB WEB_SAFARI"))
        #expect(walls(.visionOS, [.webEmbed], [], [.visionOS], live: false)
                == Self.android("TV_TIZEN VISIONOS ANDROID_REEL ANDROID_VR IOS MWEB WEB WEB_SAFARI WEB_EMBED"))
        #expect(walls(nil, [], [], [.visionOS], live: false)
                == Self.android("VISIONOS WEB_EMBED TV_TIZEN ANDROID_REEL ANDROID_VR IOS MWEB WEB WEB_SAFARI"))
    }

    @Test func anAgeGateIsSettledOnceEverySourceThatServesOneAnsweredIt() {
        #expect(!SourcePlanner.isAgeGateSettled(lane: .signedOut, ageGated: true, refused: [.visionOS], attempted: [.visionOS],
                                                remaining: [.webEmbed, .androidVR]))
        #expect(SourcePlanner.isAgeGateSettled(lane: .signedOut, ageGated: true, refused: [.visionOS, .webEmbed],
                                               attempted: [.visionOS, .webEmbed], remaining: [.androidVR]))
        #expect(!SourcePlanner.isAgeGateSettled(lane: .signedOut, ageGated: true, refused: [.visionOS],
                                                attempted: [.visionOS, .webEmbed], remaining: [.androidVR]))
        #expect(!SourcePlanner.isAgeGateSettled(lane: .signedOut, ageGated: false, refused: [.visionOS, .webEmbed],
                                                attempted: [.visionOS, .webEmbed], remaining: []))
        #expect(!SourcePlanner.isAgeGateSettled(lane: .signedIn, ageGated: true, refused: [.visionOS, .tvTizen],
                                                attempted: [.visionOS, .tvTizen], remaining: [.webEmbed, .androidVR]))
        #expect(SourcePlanner.isAgeGateSettled(lane: .signedIn, ageGated: true, refused: [.visionOS, .tvTizen, .webEmbed],
                                               attempted: [.visionOS, .tvTizen, .webEmbed], remaining: [.androidVR]))
        #expect(SourcePlanner.isAgeGateSettled(lane: .signedIn, ageGated: true, refused: [.visionOS, .webEmbed],
                                               attempted: [.visionOS, .webEmbed], remaining: [.androidVR]))
        #expect(!SourcePlanner.isAgeGateSettled(lane: .signedOut, ageGated: true, refused: [], attempted: [], remaining: [.webEmbed]))
    }
}
