import Foundation
import ObjectiveC.runtime

@objc private protocol KaraokeSeeking {
    func seekForwardBySeconds(_ seconds: Double)
    func seekBackwardBySeconds(_ seconds: Double)
    var seekingAllowed: Bool { get }
}

/// Tracks live playback position and the current track's Spotify ID, for the
/// karaoke overlay's animation loop.
///
/// Kept as its own observer/store (registered separately, see
/// KaraokeHooks.x.swift) rather than reading through SponsorBlockSkipper
/// directly, so the karaoke feature has no dependency on SponsorBlock being
/// enabled or its internal state machine.
final class KaraokePlaybackTracker {
    static let shared = KaraokePlaybackTracker()

    private let queue = DispatchQueue(label: "com.eevee.karaoke.playback")

    private var lastReportedPosition: Double?
    private var positionCorrection: Double = 0
    private var correctionRate: Double = 0
    private var seekIssuedAt: TimeInterval = 0
    private var lastPosition: Double = 0
    private var lastPositionStamp: TimeInterval = 0
    private var lastPlaybackSpeed: Double = 1.0
    private var lastIsPlaying: Bool = false
    private var lastTrackId: String?
    // Only ever set from the player observer, unlike lastTrackId (which a lyrics fetch also sets).
    private var observedTrackId: String?
    private var canvasURL: URL?

    private var didDumpStateShape = false
    private weak var playbackController: NSObject?

    private init() {}

    /// Call from the player-state-change observer with the raw state object.
    ///
    /// The key names below ("track"/"URI"/"position"/"playbackSpeed"/
    /// "isPlaying") were the assumed shape of the OLD SPTPlayerServiceImplementation
    /// -addPlayerObserver: callback's state object. As of the 9.1.78 IPA I
    /// inspected, that whole registration path doesn't exist anymore — the
    /// real one is SPTEsperantoPlayer (obtained via provideStateObservable(),
    /// see KaraokeHooks.x.swift) calling didChangeState: with an SPTPlayerState
    /// object, which is a DIFFERENT class than whatever the old assumed shape
    /// was modeled on, and its actual property names haven't been confirmed
    /// yet.
    ///
    /// Every value(forKey:) below is now guarded with responds(to:) first —
    /// calling value(forKey:) with a key the object doesn't actually have
    /// raises an uncatchable NSException (an actual crash, not a Swift nil),
    /// so guessing these key names unguarded against a still-unconfirmed
    /// class would be a real regression risk now that this is actually being
    /// called (previously safe purely because the broken hook meant this
    /// function was never invoked in practice). If any of these keys turn
    /// out wrong, this just silently keeps the previous/default value for
    /// that field rather than crashing — see the one-time dump below for
    /// getting the REAL key names for a proper follow-up fix.
    func processStateChange(state: AnyObject) {
        if !didDumpStateShape {
            didDumpStateShape = true
            karaokeDumpClassMethods("playerState", of: state)
        }

        func safeValue(_ key: String) -> Any? {
            guard state.responds(to: Selector(key)) else { return nil }
            return state.value(forKey: key)
        }

        let trackObj = safeValue("track") as AnyObject?
        let canvasSelector = NSSelectorFromString("metadataValueForKey:")
        let reportedCanvas = trackObj.flatMap { track -> URL? in
            guard track.responds(to: canvasSelector),
                  let value = track.perform(canvasSelector, with: "canvas.url")?.takeUnretainedValue() as? String,
                  let url = URL(string: value), url.scheme == "https" else { return nil }
            return url
        }
        let uriObj: Any? = trackObj.flatMap { obj -> Any? in
            guard obj.responds(to: Selector("URI")) else { return nil }
            return obj.value(forKey: "URI")
        }
        let uriString: String = {
            if let s = uriObj as? String { return s }
            if let u = uriObj as? URL { return u.absoluteString }
            return ""
        }()

        // spotify:track:<id> — same extraction style used elsewhere in the
        // codebase for episode URIs (extractEpisodeID in SponsorBlockSkipper).
        let trackId: String? = uriString.hasPrefix("spotify:track:")
            ? String(uriString.dropFirst("spotify:track:".count))
            : nil

        let positionRaw = (safeValue("position") as? NSNumber)?.doubleValue
        let fallback = queue.sync { (lastPlaybackSpeed, lastIsPlaying) }
        let playbackSpeed: Double = (safeValue("playbackSpeed") as? NSNumber)?.doubleValue ?? fallback.0
        let isPlaying: Bool = (safeValue("isPlaying") as? Bool) ?? fallback.1

        // A state whose item is not a music track (podcast episode, ad, local file)
        // means the previous track's lyrics no longer apply.
        let isNonTrackItem = trackId == nil && !uriString.isEmpty

        let receivedAt = uptimeSec()
        queue.async {
            let elapsed = self.lastPositionStamp == 0 ? 0 : max(0, receivedAt - self.lastPositionStamp)
            let changedTrack = trackId != nil && trackId != self.observedTrackId
            if let reportedCanvas { self.canvasURL = reportedCanvas }
            else if changedTrack || isNonTrackItem { self.canvasURL = nil }
            let applied = self.lastIsPlaying && self.lastPlaybackSpeed > 0 ? min(abs(self.positionCorrection), elapsed * abs(self.correctionRate)) * (self.positionCorrection < 0 ? -1 : 1) : 0
            let projected = self.lastPosition + (self.lastIsPlaying ? elapsed * self.lastPlaybackSpeed : 0) + applied
            let error = (positionRaw ?? projected) - projected
            let awaitingSeek = self.seekIssuedAt > 0 && receivedAt - self.seekIssuedAt < 1 && abs(error) > 0.75 && !changedTrack
            if awaitingSeek {
                self.lastPosition = projected
                self.positionCorrection = 0
            } else if !changedTrack, self.lastIsPlaying, isPlaying, let measured = positionRaw,
                      self.lastReportedPosition.map({ abs($0 - measured) < 0.001 }) == true {
                self.lastPosition = projected
                self.positionCorrection -= applied
            } else if !changedTrack, self.lastIsPlaying, isPlaying, playbackSpeed > 0, positionRaw != nil, abs(error) < 0.35 {
                self.lastPosition = projected
                self.positionCorrection = error
                self.correctionRate = min(0.25, max(-0.25, error / 0.3))
                self.seekIssuedAt = 0
            } else {
                self.lastPosition = positionRaw ?? (changedTrack ? 0 : projected)
                self.positionCorrection = 0
                self.correctionRate = 0
                self.seekIssuedAt = 0
            }
            if !awaitingSeek, let positionRaw { self.lastReportedPosition = positionRaw }
            else if changedTrack { self.lastReportedPosition = nil }

            self.lastPositionStamp = receivedAt
            self.lastPlaybackSpeed = playbackSpeed
            self.lastIsPlaying = isPlaying

            let previousTrackId = self.lastTrackId
            let previousObservedTrackId = self.observedTrackId
            if let trackId = trackId, !trackId.isEmpty {
                self.lastTrackId = trackId
                self.observedTrackId = trackId
            } else if isNonTrackItem {
                self.lastTrackId = nil
                self.observedTrackId = nil
            }
            // Button visibility follows the track, so tell it when the track changes.
            if self.lastTrackId != previousTrackId || self.observedTrackId != previousObservedTrackId {
                KaraokeLyricsStore.shared.notify()
                if let trackId = self.observedTrackId {
                    DispatchQueue.main.async { prefetchLyricsIfNeeded(trackId: trackId) }
                }
            }
        }
    }

    func updateTrackIdFromLyricsFetch(_ trackId: String) {
        guard !trackId.isEmpty else { return }
        queue.async {
            guard self.observedTrackId == nil, self.lastTrackId != trackId else { return }
            self.lastTrackId = trackId
            KaraokeLyricsStore.shared.notify()
        }
    }

    func attachPlaybackController(_ controller: NSObject) {
        playbackController = controller
    }

    /// Use Spotify's own transport controller, independently of gesture/SponsorBlock settings.
    @discardableResult
    func seek(toMs milliseconds: Int) -> Bool {
        guard let controller = playbackController,
              controller.responds(to: NSSelectorFromString("seekForwardBySeconds:")),
              controller.responds(to: NSSelectorFromString("seekBackwardBySeconds:")) else {
            writeDebugLog("[Karaoke] tap seek unavailable: playback controller missing")
            return false
        }
        let player = unsafeBitCast(controller, to: KaraokeSeeking.self)
        if controller.responds(to: NSSelectorFromString("seekingAllowed")), !player.seekingAllowed { return false }
        let target = max(0, milliseconds)
        let delta = Double(target - currentPositionMs()) / 1000
        if delta >= 0 { player.seekForwardBySeconds(delta) }
        else { player.seekBackwardBySeconds(-delta) }
        queue.async {
            self.lastPosition = Double(target) / 1000
            self.lastPositionStamp = self.uptimeSec()
            self.seekIssuedAt = self.lastPositionStamp
            self.positionCorrection = 0
            self.correctionRate = 0
        }
        writeDebugLog("[Karaoke] tap seek to \(target)ms")
        return true
    }

    /// Estimated current playback position in milliseconds, interpolated
    /// between actual state-change callbacks the same way SponsorBlockSkipper
    /// does — needed because callbacks don't fire every frame, but the
    /// karaoke animation needs a smooth value every frame.
    func currentPositionMs() -> Int {
        queue.sync {
            let elapsed = (lastPositionStamp == 0) ? 0 : (uptimeSec() - lastPositionStamp)
            let estSeconds = lastIsPlaying
                ? lastPosition + elapsed * lastPlaybackSpeed
                : lastPosition
            let correction = lastIsPlaying && lastPlaybackSpeed > 0 ? min(abs(positionCorrection), elapsed * abs(correctionRate)) * (positionCorrection < 0 ? -1 : 1) : 0
            return Int(max(0, estSeconds + correction) * 1000)
        }
    }

    /// The track the player itself reports as playing, or nil when the observer hasn't reported one.
    func playerReportedTrackId() -> String? {
        queue.sync { observedTrackId }
    }

    func currentTrackId() -> String? {
        queue.sync { lastTrackId }
    }

    func isPlaying() -> Bool {
        queue.sync { lastIsPlaying }
    }

    func canvasSnapshot() -> (track: String?, url: URL?, playing: Bool) {
        queue.sync { (observedTrackId, canvasURL, lastIsPlaying) }
    }

    private func uptimeSec() -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000.0
    }
}
