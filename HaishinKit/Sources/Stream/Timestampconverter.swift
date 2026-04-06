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

    // Ancre de session — capturée une seule fois au premier buffer
    private var sessionAnchorLocalMs: Int64 = 0
    private var sessionAnchorAbsoluteMs: Int64 = 0
    private var isSessionAnchored = false

    public init(clock: CMClock = CMClockGetHostTimeClock()) {
        self.hostClock = clock

        let unixMs = Int64(Date().timeIntervalSince1970 * 1000)
        let time = CMClockGetTime(clock)
        let hostMs = (time.isNumeric && time.timescale != 0)
            ? Int64((time.seconds * 1000.0).rounded())
            : 0
        self.globalOffsetMs = unixMs - hostMs
    }
    
    // MARK: - Offset management

    /// Met à jour l'offset global depuis NTP.
    /// Appelé une fois au démarrage du premier stream.
    public func updateOffset(_ offsetMs: Int64) {
        lock.lock()
        globalOffsetMs += offsetMs
        let total = globalOffsetMs
        print("🌐 [NTP] offset appliqué: \(offsetMs)ms — offset total: \(total)ms")
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
            print("🕐 [TimestampConverter] localTime invalide, fallback: \(fallback)")
            return fallback
        }
        let localMs = Int64((localTime.seconds * 1000.0).rounded())
        let offset = currentOffset()
        let result = localMs + offset
        print("🕐 [TimestampConverter] localMs: \(localMs), offset: \(offset), result: \(result)")
        return result
    }

    // MARK: - MPEG-TS / SRT conversion (90kHz)

    /// Convertit un temps absolu Unix (ms) vers un PTS MPEG-TS 90 kHz ancré sur l'epoch.
    /// PTS 33 bits max à 90kHz → wrap-around toutes les ~26.5h.
    /// Produit un timestamp absolu du type 1775204205123 * 90 mod 2^33
    /// permettant la synchro inter-devices sans base de départ commune.
    /// epoch journalière, tient dans 33 bits, identique sur tous les devices NTP-sync
    public func toPTS90k(absoluteMs: Int64) -> Int64 {
        // On prend le temps depuis minuit UTC du jour courant.
        // Max = 86_400_000 ms * 90 = 7_776_000_000 — tient dans 33 bits (max 8_589_934_591).
        // Deux devices synchronisés NTP auront exactement la même valeur pour la même frame.
        let msSinceMidnight = absoluteMs % (24 * 3600 * 1000)
        return msSinceMidnight * 90
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
    
    // MARK: - Calibration sur buffer réel

    /// Recalibre l'offset global en utilisant un CMSampleBuffer fraîchement capturé.
    /// À appeler sur le PREMIER buffer vidéo ou audio reçu dans publish().
    /// Garantit que absoluteTimeMs(fromLocalTime:) est ancré sur la même
    /// horloge que les presentationTimeStamp des buffers AVFoundation.
    public func calibrate(with sampleBuffer: CMSampleBuffer) {
        let pts = sampleBuffer.presentationTimeStamp
        guard pts.isNumeric, pts.timescale != 0, pts.seconds > 0 else { return }
        
        let unixMs = Int64(Date().timeIntervalSince1970 * 1000)
        let ptsMs  = Int64((pts.seconds * 1000.0).rounded())
        
        lock.lock()
        globalOffsetMs = unixMs - ptsMs
        lock.unlock()
        
        print("🔧 [TimestampConverter] Calibrated: unixMs=\(unixMs) ptsMs=\(ptsMs) newOffset=\(unixMs - ptsMs)")
    }

    /// Même chose à partir d'un AVAudioTime (pour calibration sur buffer audio).
    public func calibrate(with audioTime: AVAudioTime) {
        let localTime = audioTime.makeTime()
        guard localTime.isNumeric, localTime.timescale != 0, localTime.seconds > 0 else { return }
        
        let unixMs = Int64(Date().timeIntervalSince1970 * 1000)
        let ptsMs  = Int64((localTime.seconds * 1000.0).rounded())
        
        lock.lock()
        globalOffsetMs = unixMs - ptsMs
        lock.unlock()
        
        print("🔧 [TimestampConverter] Calibrated (audio): unixMs=\(unixMs) ptsMs=\(ptsMs) newOffset=\(unixMs - ptsMs)")
        // Log post-calibration — offset maintenant ancré sur les vrais buffers
        let absoluteNow = absoluteTimeMs()
        let realUnixNow = Int64(Date().timeIntervalSince1970 * 1000)
        let diff = absoluteNow - realUnixNow
        print("🔧 [TimestampConverter] Calibrated (audio): unixMs=\(unixMs) ptsMs=\(ptsMs) newOffset=\(unixMs - ptsMs)")
        print("✅ [TimestampConverter] Post-calibration check: absoluteMs=\(absoluteNow) realUnixMs=\(realUnixNow) diff=\(diff)ms")
    }

    /// Ancre la session sur le premier buffer reçu.
    /// Audio et vidéo partagent EXACTEMENT la même origine.
    public func anchorSession(localMs: Int64) {
        lock.lock()
        defer { lock.unlock() }
        guard !isSessionAnchored else { return }
        sessionAnchorLocalMs = localMs
        sessionAnchorAbsoluteMs = localMs + globalOffsetMs
        isSessionAnchored = true
        let realUnix = Int64(Date().timeIntervalSince1970 * 1000)
        let diff = sessionAnchorAbsoluteMs - realUnix
        print("⚓ [Anchor] localMs=\(localMs) → absolu=\(sessionAnchorAbsoluteMs) — diff avec Date()=\(diff)ms")
    }

    /// Convertit un temps local en absolu en utilisant l'ancre de session.
    /// Garantit la cohérence A/V : même drift, même origine.
    public func absoluteMsFromAnchor(localMs: Int64) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        guard isSessionAnchored else { return localMs + globalOffsetMs }
        // On conserve exactement le delta local, on le transpose dans l'espace absolu
        let deltaFromAnchor = localMs - sessionAnchorLocalMs
        return sessionAnchorAbsoluteMs + deltaFromAnchor
    }

    public func resetSession() {
        lock.lock()
        isSessionAnchored = false
        sessionAnchorLocalMs = 0
        sessionAnchorAbsoluteMs = 0
        lock.unlock()
        print("🔁 [Anchor] session reset")
    }
}
