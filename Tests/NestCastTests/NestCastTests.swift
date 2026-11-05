import Testing
import Foundation
import CoreAudio
import Network
@testable import NestCastKit

@Suite("NestCast Production Test Suite")
struct NestCastTests {
    
    // MARK: - Test 1: CastDevice Model & Serialization
    @Test("CastDevice model mutation & JSON serialization round-trip")
    func testCastDeviceModelSerialization() throws {
        var dev = CastDevice(
            id: "dev-surya",
            name: "Surya speaker",
            model: "Google Nest Mini",
            host: "192.168.1.4",
            port: 8009,
            volume: 0.65
        )
        #expect(dev.id == "dev-surya")
        #expect(dev.name == "Surya speaker")
        #expect(dev.model == "Google Nest Mini")
        #expect(dev.host == "192.168.1.4")
        #expect(dev.port == 8009)
        #expect(abs(dev.volume - 0.65) < 0.001)
        
        dev.volume = 0.85
        #expect(abs(dev.volume - 0.85) < 0.001)
        
        let encoded = try JSONEncoder().encode(dev)
        let decoded = try JSONDecoder().decode(CastDevice.self, from: encoded)
        #expect(decoded.id == "dev-surya")
        #expect(decoded.name == "Surya speaker")
        #expect(abs(decoded.volume - 0.85) < 0.001)
        #expect(decoded.host == "192.168.1.4")
        #expect(decoded.port == 8009)
    }
    
    // MARK: - Test 2: Native 48kHz WAV Synthesis & PCM Header
    @Test("Native 48kHz WAV synthesis & PCM header integrity")
    func testNative48kHzWAVSynthesis() {
        let wavData = AudioStreamServer.generateChimeWAV()
        #expect(wavData.count > 44, "WAV size must exceed standard 44-byte header")
        
        // RIFF header
        let riff = String(data: wavData.prefix(4), encoding: .ascii)
        #expect(riff == "RIFF", "Magic header must be RIFF")
        
        // Format WAVE
        let wave = String(data: wavData.subdata(in: 8..<12), encoding: .ascii)
        #expect(wave == "WAVE", "Format must be WAVE")
        
        // fmt chunk
        let fmtChunk = String(data: wavData.subdata(in: 12..<16), encoding: .ascii)
        #expect(fmtChunk == "fmt ", "Subchunk1 ID must be 'fmt '")
        
        // AudioFormat: PCM (1)
        let audioFormat = wavData.subdata(in: 20..<22).withUnsafeBytes { $0.load(as: UInt16.self) }
        #expect(audioFormat == 1, "Audio format must be PCM (1)")
        
        // NumChannels: Mono (1)
        let channels = wavData.subdata(in: 22..<24).withUnsafeBytes { $0.load(as: UInt16.self) }
        #expect(channels == 1, "Channel count must be mono (1)")
        
        // SampleRate: 48000 Hz (DAC native)
        let sampleRate = wavData.subdata(in: 24..<28).withUnsafeBytes { $0.load(as: UInt32.self) }
        #expect(sampleRate == 48000, "Sample rate must match native 48kHz DAC")
        
        // BitsPerSample: 16-bit
        let bitsPerSample = wavData.subdata(in: 34..<36).withUnsafeBytes { $0.load(as: UInt16.self) }
        #expect(bitsPerSample == 16, "Bits per sample must be 16-bit")
        
        // data chunk
        let dataChunk = String(data: wavData.subdata(in: 36..<40), encoding: .ascii)
        #expect(dataChunk == "data", "Subchunk2 ID must be 'data'")
    }
    
    // MARK: - Test 3: Protobuf Wire Framing & Decoder
    @Test("Protobuf wire framing and binary field extraction")
    @MainActor
    func testProtobufFramingAndDecoder() {
        let cp = CastProtocol()
        let sampleJson = "{\"type\":\"GET_STATUS\",\"requestId\":101,\"extra\":\"{nested:value}\"}"
        let packet = cp.encodeCastMessage(
            source: "sender-0",
            dest: "receiver-0",
            ns: "urn:x-cast:com.google.cast.receiver",
            json: sampleJson
        )
        
        // Wire protocol prefix: 4-byte big-endian payload length
        #expect(packet.count > 4)
        let payloadLen = packet.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        #expect(Int(payloadLen) == packet.count - 4, "Length prefix must match payload length")
        
        // Protobuf Decoder: strict binary field parsing without brace counting
        let payloadData = packet.subdata(in: 4..<packet.count)
        guard let decoded = ProtobufDecoder.decodeCastMessage(from: payloadData) else {
            Issue.record("Failed to decode valid CastProtobufMessage")
            return
        }
        
        #expect(decoded.protocolVersion == 0)
        #expect(decoded.sourceId == "sender-0")
        #expect(decoded.destinationId == "receiver-0")
        #expect(decoded.namespace == "urn:x-cast:com.google.cast.receiver")
        #expect(decoded.payloadType == 0)
        #expect(decoded.payloadUtf8 == sampleJson, "Decoded JSON payload must match original exactly")
    }
    
    // MARK: - Test 4: Protobuf Decoder Resiliency against Malformed Inputs
    @Test("Protobuf decoder resiliency against malformed and corrupted payloads")
    func testProtobufDecoderMalformedInputs() {
        // Empty data
        #expect(ProtobufDecoder.decodeCastMessage(from: Data()) == nil)
        
        // Truncated varint tag
        let truncatedTag = Data([0x80])
        let partial = ProtobufDecoder.decodeCastMessage(from: truncatedTag)
        #expect(partial != nil) // Should terminate cleanly without hanging or crashing
        
        // String length exceeds payload
        let corruptLen = Data([0x12, 0x50, 0x41, 0x42]) // Tag 2 (sourceId), length 80, but only 2 bytes follow
        let corruptResult = ProtobufDecoder.decodeCastMessage(from: corruptLen)
        #expect(corruptResult != nil)
        #expect(corruptResult?.sourceId == "", "Corrupt string length must not cause out-of-bounds crash")
    }
    
    // MARK: - Test 5: CastProtocol State & MEDIA_STATUS Transitions
    @Test("CastProtocol MEDIA_STATUS playback state transitions")
    @MainActor
    func testCastProtocolStateTransitions() {
        let cp = CastProtocol()
        #expect(cp.state == .disconnected)
        
        // BUFFERING status
        let bufferingPayload: [String: Any] = [
            "type": "MEDIA_STATUS",
            "status": [
                [
                    "mediaSessionId": 42,
                    "playerState": "BUFFERING"
                ]
            ]
        ]
        cp.handleJsonMessage(bufferingPayload)
        #expect(cp.state == .buffering)
        #expect(cp.currentMediaSessionId == 42)
        
        // PLAYING status
        let playingPayload: [String: Any] = [
            "type": "MEDIA_STATUS",
            "status": [
                [
                    "mediaSessionId": 42,
                    "playerState": "PLAYING"
                ]
            ]
        ]
        cp.handleJsonMessage(playingPayload)
        #expect(cp.state == .playing)
        
        // IDLE with ERROR
        let errorPayload: [String: Any] = [
            "type": "MEDIA_STATUS",
            "status": [
                [
                    "mediaSessionId": 42,
                    "playerState": "IDLE",
                    "idleReason": "ERROR"
                ]
            ]
        ]
        cp.handleJsonMessage(errorPayload)
        if case .error(let msg) = cp.state {
            #expect(msg.contains("error on speaker"))
        } else {
            Issue.record("State should transition to .error on IDLE with ERROR")
        }
    }
    
    // MARK: - Test 6: AppId Matching (CC1AD845 Isolation)
    @Test("Cast receiver application filtering (CC1AD845 isolation)")
    @MainActor
    func testAppIdMatchingCC1AD845() {
        let cp = CastProtocol()
        
        // Status with foreign application (e.g. YouTube or Dashboard)
        let foreignStatus: [String: Any] = [
            "type": "RECEIVER_STATUS",
            "status": [
                "applications": [
                    [
                        "appId": "233637DE", // YouTube
                        "transportId": "foreign-transport-1",
                        "sessionId": "foreign-session-1"
                    ]
                ]
            ]
        ]
        cp.handleJsonMessage(foreignStatus)
        #expect(cp.currentTransportId == nil, "Foreign appId must NOT satisfy receiver transport")
        #expect(cp.currentSessionId == nil, "Foreign appId must NOT satisfy receiver session")
        
        // Status with Default Media Receiver CC1AD845
        let dmrStatus: [String: Any] = [
            "type": "RECEIVER_STATUS",
            "status": [
                "applications": [
                    [
                        "appId": "CC1AD845", // Default Media Receiver
                        "transportId": "dmr-transport-99",
                        "sessionId": "dmr-session-99"
                    ]
                ]
            ]
        ]
        cp.handleJsonMessage(dmrStatus)
        #expect(cp.currentTransportId == "dmr-transport-99", "CC1AD845 must correctly bind transportId")
        #expect(cp.currentSessionId == "dmr-session-99", "CC1AD845 must correctly bind sessionId")
    }
    
    // MARK: - Test 7: Multizone Volume Updates
    @Test("Multizone DEVICE_UPDATED volume synchronization")
    @MainActor
    func testVolumeUpdatesAndAdjustmentProtection() {
        let cp = CastProtocol()
        let dev = CastDevice(id: "surya-1", name: "Surya speaker", host: "192.168.1.4", volume: 0.5)
        cp.activeDevice = dev
        
        // Multizone device volume update
        let multiZoneMsg: [String: Any] = [
            "type": "DEVICE_UPDATED",
            "device": [
                "name": "Surya speaker",
                "volume": ["level": 0.72]
            ]
        ]
        cp.handleJsonMessage(multiZoneMsg)
        #expect(abs(cp.currentVolume - 0.72) < 0.01)
        #expect(abs((cp.activeDevice?.volume ?? 0.0) - 0.72) < 0.01)
    }
    
    // MARK: - Test 8: AudioDeviceManager Safe Idempotent Output Restoration
    @Test("AudioDeviceManager safe idempotent restoration")
    func testAudioDeviceManagerIdempotency() {
        let adm = AudioDeviceManager()
        
        // If NestCast has not redirected output (isRedirectedToBlackHole == false),
        // restoreOriginalOutput() MUST be a complete no-op and never hijack the default output.
        #expect(!adm.isRedirectedToBlackHole)
        let restored = adm.restoreOriginalOutput()
        #expect(restored, "restoreOriginalOutput() returns true safely without modifying output")
        #expect(!adm.isRedirectedToBlackHole)
    }
    
    // MARK: - Test 9: LogManager Token Sanitization & File Persistence
    @Test("LogManager sensitive session token sanitization")
    func testLogManagerTokenSanitization() {
        let logger = LogManager.shared
        let urlWithToken = "http://192.168.1.5:8088/live.mp3?token=550e8400-e29b-41d4-a716-446655440000"
        let sanitized = logger.sanitize(urlWithToken)
        #expect(!sanitized.contains("550e8400-e29b-41d4-a716-446655440000"), "Sensitive token must be redacted")
        #expect(sanitized.contains("token=[REDACTED]"), "Token must be replaced with [REDACTED]")
        
        // Test logging to file
        let logPath = logger.getLogFilePath()
        #expect(FileManager.default.fileExists(atPath: logPath), "Log file must exist on disk")
    }
    
    // MARK: - Test 10: System Infrastructure (CoreAudio & SoX Availability)
    @Test("System infrastructure audio pipeline (BlackHole & SoX)")
    func testSystemInfrastructureAudioPipeline() {
        let adm = AudioDeviceManager()
        let hasBlackHole = adm.isBlackHoleInstalled()
        #expect(hasBlackHole, "BlackHole 2ch virtual audio driver must be installed for desktop capture")
        
        let soxExists = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/sox") ||
                        FileManager.default.isExecutableFile(atPath: "/usr/local/bin/sox")
        #expect(soxExists, "SoX audio encoding binary must be installed and executable")
    }
}
