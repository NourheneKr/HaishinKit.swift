import Foundation

/// Contexte temporel d'un stream.
///
/// Fige un instant de départ commun au flux.
/// Tous les PTS du stream sont calculés relativement à cette origine.
/// Créé une seule fois par connexion dans publish().
public struct StreamClockContext: Sendable {
    /// Temps absolu de début du stream en millisecondes.
    /// Basé sur Unix time + offset NTP.
    public let startAbsoluteMs: Int64

    /// Crée un nouveau contexte en figeant l'instant courant.
    public init(converter: TimestampConverter = .shared) {
        self.startAbsoluteMs = converter.absoluteTimeMs()
    }
}