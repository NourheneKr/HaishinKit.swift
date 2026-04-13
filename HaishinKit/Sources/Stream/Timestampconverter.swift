import Foundation
import CoreMedia
import AVFoundation

/// Centralise toute la logique de conversion temporelle.
///
/// Objectif:
/// - partir d'une horloge locale monotone (CMClockGetHostTimeClock)
/// - appliquer un offset NTP global partagé
/// - produire un timestamp absolu en millisecondes
/// - convertir ce temps en PTS MPEG-TS (90 kHz) ou RTMP (ms)
///
/// Singleton partagé entre SRT et RTMP.
public final class TimestampConverter: @unchecked Sendable {
    public static let shared = TimestampConverter()

    /// Horloge monotone locale CoreMedia.
    private let hostClock: CMClock

    /// Offset global en millisecondes.
    /// Formula: absoluteTimeMs = hostTimeMs + globalOffsetMs
    private var globalOffsetMs: Int64

    private let lock = NSLock()

    private var isCalibrated = false

    // Ancres séparées audio / vidéo
    private var videoAnchorLocalMs: Int64 = 0
    private var videoAnchorAbsoluteMs: Int64 = 0
    private var isVideoAnchored = false

    private var audioAnchorLocalMs: Int64 = 0
    private var audioAnchorAbsoluteMs: Int64 = 0
    private var isAudioAnchored = false

    public init(clock: CMClock = CMClockGetHostTimeClock()) {
        self.hostClock = clock

        let unixMs = Int64(Date().timeIntervalSince1970 * 1000)
        let time = CMClockGetTime(clock)

        print("[TimestampConverter] init — time.isNumeric=\(time.isNumeric) time.seconds=\(time.seconds) timescale=\(time.timescale)")

        let hostMs = (time.isNumeric && time.timescale != 0)
            ? Int64((time.seconds * 1000.0).rounded())
            : 0
        self.globalOffsetMs = unixMs - hostMs

        print("[TimestampConverter] init — hostMs=\(hostMs) unixMs=\(unixMs) globalOffsetMs=\(globalOffsetMs)")
    }
    
    // MARK: - Offset management

    /// Met à jour l'offset global depuis NTP.
    /// Appelé une fois au démarrage du premier stream.
    public func updateOffset(_ offsetMs: Int64) {
        lock.lock()
        globalOffsetMs += offsetMs
        lock.unlock()
    }

    /// Retourne l'offset courant.
    public func currentOffset() -> Int64 {
        lock.lock()
        let offset = globalOffsetMs
        lock.unlock()
        return offset
    }

    // MARK: - Local / absolute time

    /// Temps monotone local du device en millisecondes.
    public func hostTimeMs() -> Int64 {
        let time = CMClockGetTime(hostClock)
        guard time.isNumeric, time.timescale != 0 else { return 0 }
        return Int64((time.seconds * 1000.0).rounded())
    }

    /// Temps absolu partagé en millisecondes.
    /// absoluteTimeMs = localHostTimeMs + globalOffsetMs
    public func absoluteTimeMs() -> Int64 {
        return hostTimeMs() + currentOffset()
    }

    /// Convertit un CMTime local en temps absolu ms.
    public func absoluteTimeMs(fromLocalTime localTime: CMTime) -> Int64 {
        guard localTime.isNumeric, localTime.timescale != 0 else {
            let fallback = absoluteTimeMs()
            return fallback
        }
        let localMs = Int64((localTime.seconds * 1000.0).rounded())
        let offset = currentOffset()
        let result = localMs + offset
        return result
    }

    // MARK: - MPEG-TS / SRT conversion (90kHz)

    public func toPTS90k(absoluteMs: Int64) -> Int64 {
        return (absoluteMs * 90) & ((1 << 33) - 1)
    }

    /// Convertit un PTS 90 kHz en CMTime compatible avec PESOptionalHeader.setTimestamp.
    public func pts90kAsCMTime(_ pts90k: Int64) -> CMTime {
        return CMTime(value: pts90k, timescale: 90_000)
    }

    // MARK: - RTMP conversion (ms)

    /// Convertit un temps absolu Unix (ms) vers un timestamp RTMP (UInt32 ms) ancré sur l'epoch.
    /// UInt32 max ≈ 49.7 jours → wrap-around naturel, cohérent avec le standard RTMP.
    /// Produit un timestamp absolu du type 1775204205123 & 0xFFFFFFFF
    /// permettant la synchro inter-devices sans base de départ commune.
    public func toRTMPTimestamp(absoluteMs: Int64) -> UInt32 {
        return UInt32(absoluteMs & Int64(UInt32.max))
    }
    
    // MARK: - Calibration : avec le CMTime du buffer brut
    public func calibrate(localPTS: CMTime) {
        print("[CALIBRATE] appelé avec pts=\(localPTS.seconds)s isNumeric=\(localPTS.isNumeric)")

        guard localPTS.isNumeric else {
            print("[CALIBRATE] ❌ rejeté — PTS non numérique")
            return
        }
        guard localPTS.seconds > 0 else {
            print("[CALIBRATE] ❌ rejeté — PTS trop petit: \(localPTS.seconds)s")
            return
        }

        var tv = timeval()
        gettimeofday(&tv, nil)

        let unixMs = Int64(tv.tv_sec) * 1000 + Int64(tv.tv_usec) / 1000
        let ptsMs  = Int64((localPTS.seconds * 1000).rounded())

        lock.lock()
        guard !isCalibrated else {
            print("[CALIBRATE] ⚠️ déjà calibré — skip")
            lock.unlock()
            return
        }
        globalOffsetMs = unixMs - ptsMs
        isCalibrated = true
        let offsetSnapshot = globalOffsetMs
        lock.unlock()

        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("[CALIBRATE] ✅ localPTS  = \(ptsMs)ms")
        print("[CALIBRATE] ✅ wall      = \(unixMs)ms")
        print("[CALIBRATE] ✅ newOffset = \(offsetSnapshot)ms")
        print("[CALIBRATE] ✅ vérif     = \(ptsMs + offsetSnapshot)ms ← doit = wall")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    }

    public func anchorSession(localMs: Int64, mediaType: AVMediaType) {
        lock.lock()
        defer { lock.unlock() }
        switch mediaType {
        case .video:
            guard !isVideoAnchored else { return }
            videoAnchorLocalMs = localMs
            videoAnchorAbsoluteMs = localMs + globalOffsetMs
            isVideoAnchored = true
        case .audio:
            guard !isAudioAnchored else { return }
            audioAnchorLocalMs = localMs
            audioAnchorAbsoluteMs = localMs + globalOffsetMs
            isAudioAnchored = true
        default:
            break
        }
    }

    public func absoluteMsFromAnchor(localMs: Int64, mediaType: AVMediaType) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        switch mediaType {
        case .video:
            guard isVideoAnchored else { return localMs + globalOffsetMs }
            return videoAnchorAbsoluteMs + (localMs - videoAnchorLocalMs)
        case .audio:
            guard isAudioAnchored else { return localMs + globalOffsetMs }
            return audioAnchorAbsoluteMs + (localMs - audioAnchorLocalMs)
        default:
            return localMs + globalOffsetMs
        }
    }

    public func resetSession() {
        lock.lock()
        isVideoAnchored = false
        isAudioAnchored = false
        isCalibrated = false
        videoAnchorLocalMs = 0
        videoAnchorAbsoluteMs = 0
        audioAnchorLocalMs = 0
        audioAnchorAbsoluteMs = 0
        lock.unlock()
    }
}
