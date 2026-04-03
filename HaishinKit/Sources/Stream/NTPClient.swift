import Foundation
import Network

/// Simple client SNTP pour récupérer l'offset entre l'heure locale et NTP.
///
/// Permet de synchroniser plusieurs appareils avec une précision ~1-10ms.
/// Utilise time.apple.com — disponible sur tous les appareils iOS sans config réseau.
///
/// Usage:
/// ```swift
/// let offset = await NTPClient.shared.fetchOffset()
/// TimestampConverter.shared.updateOffset(offset)
/// ```
public actor NTPClient {

    public static let shared = NTPClient()

    private let host = "time.apple.com"
    private let port: NWEndpoint.Port = 123

    /// Récupère l'offset NTP en millisecondes.
    /// Compense le round-trip time (RTT) pour une meilleure précision.
    /// Retourne 0 en cas d'erreur — l'offset initial Unix est déjà utilisé.
    public func fetchOffset() async -> Int64 {
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: port,
            using: .udp
        )
        connection.start(queue: .global())

        // Paquet NTP v3 (48 bytes) — LI=0, VN=3, Mode=3 (client)
        let request = Data([0x1B] + [UInt8](repeating: 0, count: 47))

        return await withCheckedContinuation { continuation in
            let sendTime = Date()

            connection.send(content: request, completion: .contentProcessed { _ in })

            connection.receiveMessage { data, _, _, _ in
                defer { connection.cancel() }

                let receiveTime = Date()

                guard let data, data.count >= 48 else {
                    continuation.resume(returning: 0)
                    return
                }

                // Timestamp de transmission NTP (octets 40-47)
                let transmitSeconds = data.subdata(in: 40..<44).reduce(UInt64(0)) {
                    ($0 << 8) | UInt64($1)
                }

                // Conversion NTP epoch (1900) → Unix epoch (1970)
                let ntpEpoch: UInt64 = 2_208_988_800
                guard transmitSeconds > ntpEpoch else {
                    continuation.resume(returning: 0)
                    return
                }
                let serverUnixSeconds = Int64(transmitSeconds) - Int64(ntpEpoch)

                // Temps local au moment de l'envoi
                let localUnixSeconds = Int64(sendTime.timeIntervalSince1970)

                // Compensation RTT : on soustrait la moitié du temps de trajet
                let rttMs = Int64(receiveTime.timeIntervalSince(sendTime) * 1000)
                let halfRttMs = rttMs / 2

                // Offset = différence serveur/local corrigée du RTT
                let offset = (serverUnixSeconds - localUnixSeconds) * 1000 - halfRttMs
                print("🌐 [NTPClient] serverUnixSeconds: \(serverUnixSeconds), localUnixSeconds: \(localUnixSeconds), rttMs: \(rttMs), offset: \(offset)")

                continuation.resume(returning: offset)
            }
        }
    }
}