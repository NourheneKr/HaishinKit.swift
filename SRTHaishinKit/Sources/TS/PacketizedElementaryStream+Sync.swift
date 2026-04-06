import AVFoundation
import CoreMedia
import HaishinKit

extension PacketizedElementaryStream {

    /// Initialiseur vidéo synchronisé sur une référence absolue commune.
    /// Calcule un PTS absolu basé sur Unix time + offset NTP,
    /// converti en 90kHz pour le header PES.
    init?(
        synchronizedVideoSampleBuffer sampleBuffer: CMSampleBuffer?,
        context: StreamClockContext,
        converter: TimestampConverter = .shared
    ) {
        guard let sampleBuffer, let dataBuffer = sampleBuffer.dataBuffer else {
            return nil
        }

        switch sampleBuffer.formatDescription?.mediaSubType {
        case .h264:
            if !sampleBuffer.isNotSync {
                data.append(contentsOf: [0x00, 0x00, 0x00, 0x01, 0x09, 0x10])
                sampleBuffer.formatDescription?.parameterSets.forEach {
                    data.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                    data.append(contentsOf: $0)
                }
            } else {
                data.append(contentsOf: [0x00, 0x00, 0x00, 0x01, 0x09, 0x30])
            }
            if let dataBytes = try? dataBuffer.dataBytes() {
                let stream = ISOTypeBufferUtil(data: dataBytes)
                data.append(stream.toByteStream())
            }

        case .hevc:
            if !sampleBuffer.isNotSync {
                sampleBuffer.formatDescription?.parameterSets.forEach {
                    data.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                    data.append(contentsOf: $0)
                }
            }
            if let dataBytes = try? dataBuffer.dataBytes() {
                let stream = ISOTypeBufferUtil(data: dataBytes)
                data.append(stream.toByteStream())
            }

        default:
            return nil
        }

        // 1) Calcul du temps absolu de présentation
        let absolutePresentationMs: Int64 = sampleBuffer.presentationTimeStamp.isNumeric
            ? converter.absoluteTimeMs(fromLocalTime: sampleBuffer.presentationTimeStamp)
            : converter.absoluteTimeMs()

        // 2) Calcul éventuel du temps absolu de décodage
        let absoluteDecodeMs: Int64? = sampleBuffer.decodeTimeStamp.isNumeric
            ? converter.absoluteTimeMs(fromLocalTime: sampleBuffer.decodeTimeStamp)
            : nil

        // 3) Conversion vers PTS / DTS 90kHz (absolu, ancré sur Unix epoch)
        let pts33Mask: Int64 = (1 << 33) - 1
        let pts90k = converter.toPTS90k(absoluteMs: absolutePresentationMs) & pts33Mask
        let dts90k: Int64? = absoluteDecodeMs.map { converter.toPTS90k(absoluteMs: $0) & pts33Mask }

        // 4) Injection dans l'en-tête PES
        optionalPESHeader = PESOptionalHeader()
        optionalPESHeader?.dataAlignmentIndicator = true
        optionalPESHeader?.setTimestamp(
            CMTime(value: 0, timescale: 1),
            presentationTimeStamp: converter.pts90kAsCMTime(pts90k),
            decodeTimeStamp: dts90k.map { converter.pts90kAsCMTime($0) } ?? .invalid
        )

        // 5) Longueur du paquet
        let length = data.count + (optionalPESHeader?.data.count ?? 0)
        packetLength = length < Int(UInt16.max) ? UInt16(length) : 0
    }

    /// Initialiseur audio synchronisé sur une référence absolue commune.
    /// Calcule un PTS absolu basé sur Unix time + offset NTP,
    /// converti en 90kHz pour le header PES.
    init?(
        synchronizedAudioCompressedBuffer audioCompressedBuffer: AVAudioCompressedBuffer?,
        when: AVAudioTime,
        context: StreamClockContext,
        converter: TimestampConverter = .shared
    ) {
        guard let audioCompressedBuffer else {
            return nil
        }

        // Encodage ADTS inchangé
        data = .init(count: Int(audioCompressedBuffer.byteLength) + AudioSpecificConfig.adtsHeaderSize)
        audioCompressedBuffer.encode(to: &data)

        // 1) Récupération du temps de présentation audio
        let localAudioTime = when.makeTime()
        let absolutePresentationMs: Int64 = localAudioTime.isNumeric
            ? converter.absoluteTimeMs(fromLocalTime: localAudioTime)
            : converter.absoluteTimeMs()

        // 2) Conversion vers PTS 90kHz (absolu, ancré sur Unix epoch)
        let pts33Mask: Int64 = (1 << 33) - 1
        let pts90k = converter.toPTS90k(absoluteMs: absolutePresentationMs) & pts33Mask

        // 3) Injection dans PES
        optionalPESHeader = PESOptionalHeader()
        optionalPESHeader?.dataAlignmentIndicator = true
        optionalPESHeader?.setTimestamp(
            CMTime(value: 0, timescale: 1),
            presentationTimeStamp: converter.pts90kAsCMTime(pts90k),
            decodeTimeStamp: .invalid
        )

        // 4) Longueur du paquet
        let length = data.count + (optionalPESHeader?.data.count ?? 0)
        guard length < Int(UInt16.max) else { return nil }
        packetLength = UInt16(length)
    }
}