import AVFoundation
import CoreMedia
import Foundation
import HaishinKit

/// An object that represents writes MPEG-2 transport stream data.
final class TSWriter {
    static let defaultPATPID: UInt16 = 0
    static let defaultPMTPID: UInt16 = 4095
    static let defaultVideoPID: UInt16 = 256
    static let defaultAudioPID: UInt16 = 257
    static let defaultSegmentDuration: Double = 2

    /// An asynchronous sequence for writing data.
    public var output: AsyncStream<Data> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    /// Specifies the expected medias = [.video, .audio].
    var expectedMedias: Set<AVMediaType> = []

    /// Contexte de synchronisation temporelle.
    /// Créé dans SRTStream.publish() et passé ici.
    /// Nil = comportement original (pas de synchro inter-devices).
    var clockContext: StreamClockContext?

    /// Specifies the audio format.
    var audioFormat: AVAudioFormat? {
        didSet {
            guard let audioFormat, audioFormat != oldValue else { return }
            var data = ESSpecificData()
            data.streamType = audioFormat.formatDescription.streamType
            data.elementaryPID = Self.defaultAudioPID
            pmt.elementaryStreamSpecificData.append(data)
            audioContinuityCounter = 0
            writeProgramIfNeeded()
        }
    }

    /// Specifies the video format.
    var videoFormat: CMFormatDescription? {
        didSet {
            guard let videoFormat, videoFormat != oldValue else { return }
            var data = ESSpecificData()
            data.streamType = videoFormat.streamType
            data.elementaryPID = Self.defaultVideoPID
            pmt.elementaryStreamSpecificData.append(data)
            videoContinuityCounter = 0
            writeProgramIfNeeded()
        }
    }

    private(set) var pat: TSProgramAssociation = {
        let PAT: TSProgramAssociation = .init()
        PAT.programs = [1: TSWriter.defaultPMTPID]
        return PAT
    }()
    private(set) var pmt: TSProgramMap = .init()
    private var pcrPID: UInt16 = TSWriter.defaultVideoPID
    private var canWriteFor: Bool {
        guard !expectedMedias.isEmpty else { return true }
        if expectedMedias.contains(.audio) && expectedMedias.contains(.video) {
            return audioFormat != nil && videoFormat != nil
        }
        if expectedMedias.contains(.video) { return videoFormat != nil }
        if expectedMedias.contains(.audio) { return audioFormat != nil }
        return false
    }
    private var videoTimeStamp: CMTime = .invalid
    private var audioTimeStamp: CMTime = .invalid
    private var clockTimeStamp: CMTime = .zero
    private var segmentDuration: Double = TSWriter.defaultSegmentDuration
    private var rotatedTimeStamp: CMTime = .zero
    private var audioContinuityCounter: UInt8 = 0
    private var videoContinuityCounter: UInt8 = 0
    private var continuation: AsyncStream<Data>.Continuation? {
        didSet { oldValue?.finish() }
    }

    init(segmentDuration: Double = 2.0) {
        self.segmentDuration = segmentDuration
    }

    /// Appends an audio buffer.
    func append(_ audioBuffer: AVAudioBuffer, when: AVAudioTime) {
        guard let audioBuffer = audioBuffer as? AVAudioCompressedBuffer, canWriteFor else {
            return
        }
        if audioTimeStamp == .invalid {
            audioTimeStamp = when.makeTime()
            if pcrPID == TSWriter.defaultAudioPID {
                clockTimeStamp = audioTimeStamp
            }
        }

        // Utiliser l'initialiseur synchronisé si clockContext disponible
        // sinon fallback sur l'initialiseur original
        if let context = clockContext,
           var pes = PacketizedElementaryStream(
               synchronizedAudioCompressedBuffer: audioBuffer,
               when: when,
               context: context
           ) {
            pes.streamID = 192
            writePacketizedElementaryStream(
                TSWriter.defaultAudioPID,
                PES: pes,
                timeStamp: when.makeTime(),
                randomAccessIndicator: true
            )
        } else if var pes = PacketizedElementaryStream(audioBuffer, when: when, timeStamp: audioTimeStamp) {
            pes.streamID = 192
            writePacketizedElementaryStream(
                TSWriter.defaultAudioPID,
                PES: pes,
                timeStamp: when.makeTime(),
                randomAccessIndicator: true
            )
        }
    }

    /// Appends a video sample buffer.
    func append(_ sampleBuffer: CMSampleBuffer) {
        guard canWriteFor else { return }
        switch sampleBuffer.formatDescription?.mediaType {
        case .video:
            if videoTimeStamp == .invalid {
                videoTimeStamp = sampleBuffer.presentationTimeStamp
                if pcrPID == Self.defaultVideoPID {
                    clockTimeStamp = videoTimeStamp
                }
            }

            let timestamp = sampleBuffer.decodeTimeStamp == .invalid
                ? sampleBuffer.presentationTimeStamp
                : sampleBuffer.decodeTimeStamp

            // Utiliser l'initialiseur synchronisé si clockContext disponible
            // sinon fallback sur l'initialiseur original
            if let context = clockContext,
               var pes = PacketizedElementaryStream(
                   synchronizedVideoSampleBuffer: sampleBuffer,
                   context: context
               ) {
                pes.streamID = 224
                writePacketizedElementaryStream(
                    Self.defaultVideoPID,
                    PES: pes,
                    timeStamp: timestamp,
                    randomAccessIndicator: !sampleBuffer.isNotSync
                )
            } else if var pes = PacketizedElementaryStream(sampleBuffer, timeStamp: videoTimeStamp) {
                pes.streamID = 224
                writePacketizedElementaryStream(
                    Self.defaultVideoPID,
                    PES: pes,
                    timeStamp: timestamp,
                    randomAccessIndicator: !sampleBuffer.isNotSync
                )
            }
        default:
            break
        }
    }

    /// Clears the writer object for new transport stream.
    func clear() {
        audioFormat = nil
        audioContinuityCounter = 0
        videoFormat = nil
        videoContinuityCounter = 0
        pcrPID = Self.defaultVideoPID
        pat.programs.removeAll()
        pat.programs = [1: Self.defaultPMTPID]
        pmt = TSProgramMap()
        videoTimeStamp = .invalid
        audioTimeStamp = .invalid
        clockTimeStamp = .zero
        rotatedTimeStamp = .zero
        expectedMedias.removeAll()
        continuation = nil
        clockContext = nil  // ← reset du contexte de synchro
    }

    private func writePacketizedElementaryStream(_ PID: UInt16, PES: PacketizedElementaryStream, timeStamp: CMTime, randomAccessIndicator: Bool) {
        let packets: [TSPacket] = split(PID, PES: PES, timestamp: timeStamp)
        rotateFileHandle(timeStamp)
        packets[0].adaptationField?.randomAccessIndicator = randomAccessIndicator
        var bytes = Data()
        for var packet in packets {
            switch PID {
            case Self.defaultAudioPID:
                packet.continuityCounter = audioContinuityCounter
                audioContinuityCounter = (audioContinuityCounter + 1) & 0x0f
            case Self.defaultVideoPID:
                packet.continuityCounter = videoContinuityCounter
                videoContinuityCounter = (videoContinuityCounter + 1) & 0x0f
            default:
                break
            }
            bytes.append(packet.data)
        }
        write(bytes)
    }

    private func rotateFileHandle(_ timestamp: CMTime) {
        let duration = timestamp.seconds - rotatedTimeStamp.seconds
        guard segmentDuration < duration else { return }
        writeProgramIfNeeded()
        rotatedTimeStamp = timestamp
    }

    private func write(_ data: Data) {
        continuation?.yield(data)
    }

    private func writeProgram() {
        pmt.PCRPID = pcrPID
        var bytes = Data()
        var packets: [TSPacket] = []
        packets.append(contentsOf: pat.arrayOfPackets(Self.defaultPATPID))
        packets.append(contentsOf: pmt.arrayOfPackets(Self.defaultPMTPID))
        for packet in packets {
            bytes.append(packet.data)
        }
        write(bytes)
    }

    private func writeProgramIfNeeded() {
        guard !expectedMedias.isEmpty, canWriteFor else { return }
        writeProgram()
    }

    private func split(_ PID: UInt16, PES: PacketizedElementaryStream, timestamp: CMTime) -> [TSPacket] {
        var PCR: UInt64?
        let duration: Double = timestamp.seconds - clockTimeStamp.seconds
        if pcrPID == PID && 0.02 <= duration {
            if clockContext != nil {
                // PCR absolu ancré sur Unix epoch — cohérent avec les PTS absolus
                let absMs = TimestampConverter.shared.absoluteTimeMs(fromLocalTime: timestamp)
                let pts33Mask: UInt64 = (1 << 33) - 1  // 8_589_934_591
                PCR = UInt64(absMs * 90) & pts33Mask
            } else {
                PCR = UInt64((timestamp.seconds - (PID == Self.defaultVideoPID ? videoTimeStamp : audioTimeStamp).seconds) * TSTimestamp.resolution)
            }
            clockTimeStamp = timestamp
        }
        var packets: [TSPacket] = []
        for packet in PES.arrayOfPackets(PID, PCR: PCR) {
            packets.append(packet)
        }
        return packets
    }
}