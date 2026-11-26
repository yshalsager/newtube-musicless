import Foundation

/// Whether a walk's requests may carry the account (read once per walk; LANES §1).
public enum Lane: String, Sendable { case signedOut = "signed-out", signedIn = "signed-in" }

/// The phone's `/player` order, a port of MediaServiceCore's `PhoneSourcePlanner` (`52fecea0`;
/// docs/player-sources/LANES.md §2): one head that serves almost everything (VISIONOS), the routes
/// measured to serve what it refuses (TV_TIZEN: made-for-kids anonymously, the account route signed
/// in; WEB_EMBED: embeddable 18+; ANDROID_VR: live DASH), then an unproven tail (IOS, ANDROID_REEL).
/// Android's web clients that need a PO token (MWEB, WEB, WEB_SAFARI) are left out on iOS (PRD §4.4).
///
/// Pure: the walk (`SourceWalker`) owns everything between requests and asks this type the questions
/// that depend on the lane.
public enum SourcePlanner {
    /// The one source asked with the account when there is one.
    public static let accountRoute = ClientProfile.tvTizen
    /// The live-DASH source.
    public static let liveSource = ClientProfile.androidVR

    /// Android's `ORDER` without MWEB, WEB and WEB_SAFARI.
    public static let baseOrder: [ClientProfile] = [.visionOS, .tvTizen, .webEmbed, .androidVR, .iOS, .androidReel]

    /// The sources that serve an age-gated video in each lane (every other one answers the gate).
    static let ageGateServersSignedOut: Set<ClientProfile> = [.webEmbed]
    static let ageGateServersSignedIn: Set<ClientProfile> = [.tvTizen, .webEmbed]
    /// The only sources measured to serve a made-for-kids video.
    static let kidsServers: Set<ClientProfile> = [.tvTizen, .webEmbed]

    /// What a walk knows before its first request (Android's `PhoneSourcePlanner.Context`).
    public struct Context: Sendable {
        public var lane: Lane
        /// The source whose media just failed, for that video's recovery walk only (US-017).
        public var recoverySuspect: ClientProfile?
        /// The anonymous web identity is challenged on this network.
        public var anonChallenged = false
        /// The account route failed for this video or on this network.
        public var accountRouteBenched = false
        /// Signed in: ask the account route first (Android's A/B switch, off by default).
        public var accountRouteFirst = false
        /// This video's channel is remembered as one the account route serves and VISIONOS refuses.
        public var accountRouteHinted = false
        /// A recovery walk: sources that refused this video moments ago, asked after everything else.
        public var recoveryRefused: Set<ClientProfile> = []
        /// A recovery walk: VISIONOS or ANDROID_VR refused this video as made for kids moments ago.
        public var recoveryKidsRefused = false
        /// The app's item says live: the live-DASH source first.
        public var liveCardHinted = false
        /// The VOD order that asks ANDROID_VR after the sources surviving the one-minute wall.
        public var vodVrLate = false
        /// Sources asked last of all (walled for their visitor, or 403'd on this video).
        public var benched: Set<ClientProfile> = []
        /// A recovery's walled sources whose visitor has been re-rolled since.
        public var refreshed: Set<ClientProfile> = []

        public init(lane: Lane, recoverySuspect: ClientProfile? = nil) {
            self.lane = lane
            self.recoverySuspect = recoverySuspect
        }
    }

    /// The order for a walk that starts now. Never empty.
    public static func order(_ context: Context) -> [ClientProfile] {
        var order = baseOrder
        let account = accountRoute

        // Signed out the account route is admitted by a content refusal, not planned; signed in it
        // is planned unless it has just failed here.
        if context.lane == .signedOut || context.accountRouteBenched {
            order.removeAll { $0 == account }
        } else if context.accountRouteFirst {
            order.removeAll { $0 == account }
            order.insert(account, at: 0)
        }

        // vod-vr-late: for VOD, ANDROID_VR's media dies at the one-minute wall, so it goes after
        // TV_TIZEN (planned third signed out, anonymously) and ANDROID_REEL.
        if context.vodVrLate && !context.liveCardHinted {
            if context.lane == .signedOut && !context.accountRouteBenched && !order.contains(account) {
                let embed = order.firstIndex(of: .webEmbed)
                order.insert(account, at: embed.map { $0 + 1 } ?? order.count)
            }
            let reel = order.contains(.androidReel)
            let vr = order.contains(liveSource)
            order.removeAll { $0 == .androidReel || $0 == liveSource }
            let anchor = max(order.firstIndex(of: .webEmbed) ?? -1, order.firstIndex(of: account) ?? -1)
            let at = anchor >= 0 ? anchor + 1 : order.count
            if vr { order.insert(liveSource, at: at) }
            if reel { order.insert(.androidReel, at: at) }
        }

        // kids-channel: the account route first (never benched, never in a recovery walk).
        if context.accountRouteHinted && !context.accountRouteBenched && context.recoverySuspect == nil {
            order.removeAll { $0 == account }
            order.insert(account, at: 0)
        }

        // live-card: the live-DASH source first, VISIONOS right after (never in a recovery walk).
        if context.liveCardHinted && context.recoverySuspect == nil {
            order.removeAll { $0 == liveSource }
            order.insert(liveSource, at: 0)
        }

        // The anonymous web identity is challenged: web sources go last (stable).
        if context.anonChallenged {
            let web = order.filter(\.isWebPotRequired)
            order.removeAll(where: \.isWebPotRequired)
            order += web
        }

        // A recovery walk asks the source whose media just failed last, not never. Signed out that
        // includes TV_TIZEN (admitted by a refusal); a benched account route stays out.
        let suspect = context.recoverySuspect
        if let suspect, order.contains(suspect) {
            order.removeAll { $0 == suspect }
            order.append(suspect)
        } else if suspect == account && context.lane == .signedOut && !context.accountRouteBenched {
            order.append(account)
        }

        // recovery-kids: only TV_TIZEN and WEB_EMBED serve a made-for-kids video: the rest go behind
        // the suspect.
        if let suspect, context.recoveryKidsRefused {
            let neverServe = order.filter { $0 != suspect && !kidsServers.contains($0) }
            order.removeAll { $0 != suspect && !kidsServers.contains($0) }
            order += neverServe
        }

        // recovery-refusals: a source that refused this video moments ago goes after that.
        if let suspect, !context.recoveryRefused.isEmpty {
            var refused: [ClientProfile] = []
            for client in baseOrder where client != suspect && context.recoveryRefused.contains(client) {
                if let index = order.firstIndex(of: client) {
                    order.remove(at: index)
                    refused.append(client)
                } else if client == account && context.lane == .signedOut && !context.accountRouteBenched {
                    refused.append(client)
                }
            }
            order += refused
        }

        // playback-identity: a walled source with a re-rolled visitor comes back after WEB_EMBED and
        // TV_TIZEN, before ANDROID_REEL's 360p and ANDROID_VR.
        if suspect != nil && !context.refreshed.isEmpty {
            var again: [ClientProfile] = []
            for client in baseOrder where context.refreshed.contains(client) && !context.benched.contains(client) {
                if let index = order.firstIndex(of: client) {
                    order.remove(at: index)
                    again.append(client)
                }
            }
            var at = order.count
            for behind in [ClientProfile.androidReel, liveSource, .iOS] {
                if let index = order.firstIndex(of: behind), index < at { at = index }
            }
            order.insert(contentsOf: again, at: at)
        }

        // wall-memory: last of all, the sources walled for this visitor or 403'd on this video (a
        // live card keeps its live source first). Never adds one the walk would not ask.
        if !context.benched.isEmpty {
            var last: [ClientProfile] = []
            for client in baseOrder where context.benched.contains(client) {
                if client == liveSource && context.liveCardHinted && suspect == nil { continue }
                if let index = order.firstIndex(of: client) {
                    order.remove(at: index)
                    last.append(client)
                }
            }
            order += last
        }
        return order
    }

    /// `client` comes after the live-DASH source in the lane's own order.
    public static func isPastLiveSourceTurn(_ client: ClientProfile) -> Bool {
        guard let index = baseOrder.firstIndex(of: client), let live = baseOrder.firstIndex(of: liveSource) else { return false }
        return index > live
    }

    /// Whether an anonymous content refusal from `client` puts TV_TIZEN, without the account, next:
    /// signed out only, and not after a web source (its refusals are about the web identity or the
    /// embed policy).
    public static func admitsAccountRouteAfter(lane: Lane, client: ClientProfile) -> Bool {
        lane == .signedOut && client != accountRoute && !client.isWebPotRequired
    }

    /// The sources measured to refuse every made-for-kids video while serving ordinary ones.
    public static func refusesMadeForKids(_ client: ClientProfile) -> Bool {
        client == .visionOS || client == .androidVR
    }

    public static func servesMadeForKids(_ client: ClientProfile?) -> Bool {
        client.map(kidsServers.contains) ?? false
    }

    /// An age gate is settled once every source of the lane that serves age-gated videos has
    /// answered without serving it, or is not in this walk. A source asked but silent refused nothing.
    public static func isAgeGateSettled(lane: Lane, ageGated: Bool, refused: Set<ClientProfile>,
                                        attempted: Set<ClientProfile>, remaining: [ClientProfile]) -> Bool {
        guard ageGated else { return false }
        for server in lane == .signedIn ? ageGateServersSignedIn : ageGateServersSignedOut where !refused.contains(server) {
            if attempted.contains(server) || remaining.contains(server) { return false }
        }
        return true
    }
}
