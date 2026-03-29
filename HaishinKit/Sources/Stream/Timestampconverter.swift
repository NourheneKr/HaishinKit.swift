import Foundation
import CoreMedia

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

    public init(clock: CMClock = CMClockGetHostTimeClock()) {
        self.hostClock = clock

        // Offset initial = Unix ms - host clock ms
        // Permet d'avoir un temps absolu sans appel NTP préalable
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
        globalOffsetMs = offsetMs
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
            return absoluteTimeMs()
        }
        let localMs = Int64((localTime.seconds * 1000.0).rounded())
        return localMs + currentOffset()
    }

    // MARK: - MPEG-TS / SRT conversion (90kHz)

    /// Convertit un temps absolu (ms) vers un PTS MPEG-TS 90 kHz.
    /// 1 ms = 90 ticks à 90 kHz.
    /// Clampé à 0 pour éviter les PTS négatifs au démarrage.
    public func toPTS90k(absoluteMs: Int64, streamStartMs: Int64) -> Int64 {
        let deltaMs = max(0, absoluteMs - streamStartMs)
        return deltaMs * 90
    }

    /// Convertit un PTS 90 kHz en CMTime compatible avec PESOptionalHeader.setTimestamp.
    public func pts90kAsCMTime(_ pts90k: Int64) -> CMTime {
        return CMTime(value: pts90k, timescale: 90_000)
    }

    // MARK: - RTMP conversion (ms)

    /// Convertit un temps absolu (ms) vers un timestamp RTMP (UInt32 ms).
    /// Clampé à 0 pour éviter les valeurs négatives au démarrage.
    public func toRTMPTimestamp(absoluteMs: Int64, streamStartMs: Int64) -> UInt32 {
        let deltaMs = max(0, absoluteMs - streamStartMs)
        // UInt32 max = ~49 jours — pas d'overflow en usage normal
        return UInt32(min(deltaMs, Int64(UInt32.max)))
    }
}