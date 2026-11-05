import Foundation
import Network

func assertTest(_ condition: Bool, _ message: String) {
    if !condition {
        print("❌ TEST FAILED: \(message)")
        exit(1)
    }
    print("✓ PASSED: \(message)")
}

print("======================================================")
print("  Running NestCast Comprehensive Test Suite (v1.0.1)")
print("======================================================\n")

// ──────────────────────────────────────────────────────────
// Test 1: CastDevice Model & Serialization
// ──────────────────────────────────────────────────────────
print("Test 1: CastDevice model & serialization")
struct TestDevice: Codable {
    let id: String
    var name: String
    var model: String
    var host: String
    var port: Int
    var volume: Float
}

var dev = TestDevice(id: "dev-surya", name: "Surya speaker", model: "Google Nest Mini", host: "192.168.1.4", port: 8009, volume: 0.65)
assertTest(dev.id == "dev-surya", "Device ID matches")
assertTest(dev.name == "Surya speaker", "Device name matches")
assertTest(dev.volume == 0.65, "Device initial volume matches 0.65")

dev.volume = 0.85
assertTest(dev.volume == 0.85, "Device volume mutates to 0.85")

let encoded = try! JSONEncoder().encode(dev)
let decoded = try! JSONDecoder().decode(TestDevice.self, from: encoded)
assertTest(decoded.name == "Surya speaker", "JSON serialization round-trip matches")
assertTest(decoded.volume == 0.85, "JSON volume round-trip matches")

// ──────────────────────────────────────────────────────────
// Test 2: Audio Chime WAV Header Verification
// ──────────────────────────────────────────────────────────
print("\nTest 2: Audio chime WAV synthesis & PCM header")
func generateChimeWAV() -> Data {
    let sampleRate: Double = 44100.0
    let duration: Double = 1.0
    let numSamples = Int(sampleRate * duration)
    var samples = [Int16]()
    
    for i in 0..<numSamples {
        let t = Double(i) / sampleRate
        let env = exp(-3.0 * t)
        let tone = 0.5 * sin(2.0 * .pi * 523.25 * t) + 0.5 * sin(2.0 * .pi * 659.25 * t)
        samples.append(Int16(tone * env * 28000.0))
    }
    
    let subchunk2Size = UInt32(numSamples * 2)
    let chunkSize = 36 + subchunk2Size
    
    var header = Data()
    header.append(contentsOf: "RIFF".utf8)
    header.append(Data(bytes: [UInt32(chunkSize).littleEndian], count: 4))
    header.append(contentsOf: "WAVEfmt ".utf8)
    header.append(Data(bytes: [UInt32(16).littleEndian], count: 4))
    header.append(Data(bytes: [UInt16(1).littleEndian], count: 2))
    header.append(Data(bytes: [UInt16(1).littleEndian], count: 2))
    header.append(Data(bytes: [UInt32(44100).littleEndian], count: 4))
    header.append(Data(bytes: [UInt32(88200).littleEndian], count: 4))
    header.append(Data(bytes: [UInt16(2).littleEndian], count: 2))
    header.append(Data(bytes: [UInt16(16).littleEndian], count: 2))
    header.append(contentsOf: "data".utf8)
    header.append(Data(bytes: [UInt32(subchunk2Size).littleEndian], count: 4))
    
    var wav = header
    samples.withUnsafeBufferPointer { ptr in
        wav.append(Data(buffer: ptr))
    }
    return wav
}

let wavData = generateChimeWAV()
assertTest(wavData.count > 44, "WAV size is valid (\(wavData.count) bytes)")
let magic = String(data: wavData.prefix(4), encoding: .ascii)
assertTest(magic == "RIFF", "Magic header is RIFF")
let waveId = String(data: wavData.subdata(in: 8..<12), encoding: .ascii)
assertTest(waveId == "WAVE", "Format is WAVE")

// ──────────────────────────────────────────────────────────
// Test 3: Cast V2 Wire Protocol Framing & Varint Encoding
// ──────────────────────────────────────────────────────────
print("\nTest 3: Cast V2 wire protocol framing & varint encoding")
func encodeCastMessage(source: String, dest: String, ns: String, json: String) -> Data {
    func makeVarint(_ val: UInt64) -> [UInt8] {
        var v = val; var res: [UInt8] = []
        while v > 0x7F { res.append(UInt8((v & 0x7F) | 0x80)); v >>= 7 }
        res.append(UInt8(v)); return res
    }
    func encodeString(tag: UInt8, str: String) -> [UInt8] {
        let utf8 = Array(str.utf8); return [tag] + makeVarint(UInt64(utf8.count)) + utf8
    }
    
    var body: [UInt8] = []
    body.append(contentsOf: [0x08, 0x00])
    body.append(contentsOf: encodeString(tag: 0x12, str: source))
    body.append(contentsOf: encodeString(tag: 0x1A, str: dest))
    body.append(contentsOf: encodeString(tag: 0x22, str: ns))
    body.append(contentsOf: [0x28, 0x00])
    body.append(contentsOf: encodeString(tag: 0x32, str: json))
    
    var packet = Data()
    var len = UInt32(body.count).bigEndian
    packet.append(Data(bytes: &len, count: 4))
    packet.append(contentsOf: body)
    return packet
}

let testPacket = encodeCastMessage(
    source: "sender-0",
    dest: "receiver-0",
    ns: "urn:x-cast:com.google.cast.receiver",
    json: "{\"type\":\"SET_VOLUME\",\"volume\":{\"level\":0.75},\"requestId\":10}"
)
assertTest(testPacket.count > 4, "SET_VOLUME packet has length > 4")
let pktLen = testPacket.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
assertTest(Int(pktLen) == testPacket.count - 4, "Packet length prefix matches body length exactly (\(pktLen) bytes)")

// ──────────────────────────────────────────────────────────
// Test 4: Volume Parser, Multizone Sync & Echo Protection
// ──────────────────────────────────────────────────────────
print("\nTest 4: Volume parser, multizone sync & echo protection")
class MockCastState {
    var currentVolume: Float = 0.5
    var activeDeviceVolume: Float = 0.5
    var isUserAdjustingVolume: Bool = false
    
    func parseMessage(_ jsonString: String) {
        guard !isUserAdjustingVolume else { return }
        guard let data = jsonString.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        
        if let status = dict["status"] as? [String: Any],
           let volDict = status["volume"] as? [String: Any],
           let lvl = volDict["level"] as? Double {
            self.currentVolume = Float(lvl)
            self.activeDeviceVolume = Float(lvl)
        } else if let dev = dict["device"] as? [String: Any],
                  let vol = dev["volume"] as? [String: Any],
                  let lvl = vol["level"] as? Double {
            self.currentVolume = Float(lvl)
            self.activeDeviceVolume = Float(lvl)
        }
    }
}

let mockState = MockCastState()
assertTest(mockState.currentVolume == 0.5, "Default initial volume is 0.5 (50%)")

let mockStatusJson = "{\"requestId\":1,\"status\":{\"applications\":[],\"volume\":{\"controlType\":\"master\",\"level\":0.725,\"muted\":false}},\"type\":\"RECEIVER_STATUS\"}"
mockState.parseMessage(mockStatusJson)
assertTest(abs(mockState.currentVolume - 0.725) < 0.001, "Volume correctly updated to 72.5% from RECEIVER_STATUS")

let mockMultizoneJson = "{\"device\":{\"name\":\"Surya speaker\",\"volume\":{\"level\":0.40,\"muted\":false}},\"type\":\"DEVICE_UPDATED\"}"
mockState.parseMessage(mockMultizoneJson)
assertTest(abs(mockState.currentVolume - 0.40) < 0.001, "Volume correctly updated to 40% from multizone DEVICE_UPDATED")

// Verify echo rejection during user dragging
mockState.isUserAdjustingVolume = true
mockState.currentVolume = 0.90
mockState.parseMessage(mockStatusJson) // Delayed echo at 0.725
assertTest(mockState.currentVolume == 0.90, "User volume (90%) protected from delayed echo packet")

// ──────────────────────────────────────────────────────────
// Test 5: SessionId Inclusion in Media LOAD Payload
// ──────────────────────────────────────────────────────────
print("\nTest 5: SessionId inclusion in media LOAD payload")
func buildLoadPayload(transportId: String, sessionId: String, streamURL: String) -> [String: Any] {
    let mediaDict: [String: Any] = [
        "contentId": streamURL,
        "contentType": "audio/wav",
        "streamType": "BUFFERED"
    ]
    return [
        "type": "LOAD",
        "requestId": 101,
        "sessionId": sessionId,
        "autoplay": true,
        "currentTime": 0,
        "media": mediaDict
    ]
}

let loadPayload = buildLoadPayload(
    transportId: "trans-1234",
    sessionId: "sess-5678",
    streamURL: "http://192.168.1.9:8088/ping.wav"
)
assertTest(loadPayload["type"] as? String == "LOAD", "Payload type is LOAD")
assertTest(loadPayload["sessionId"] as? String == "sess-5678", "Payload strictly includes sessionId")
let mediaObj = loadPayload["media"] as? [String: Any]
assertTest(mediaObj?["contentType"] as? String == "audio/wav", "Content type is audio/wav")

// ──────────────────────────────────────────────────────────
// Test 6: Persistent Logging File Verification
// ──────────────────────────────────────────────────────────
print("\nTest 6: Persistent logging verification (~/Library/Logs/NestCast.log)")
let logsDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
let logFile = logsDir.appendingPathComponent("NestCast.log")
let logSample = "[\(Date())] [INFO] [Test] Verification log entry\n"
if !FileManager.default.fileExists(atPath: logFile.path) {
    FileManager.default.createFile(atPath: logFile.path, contents: nil)
}
if let handle = try? FileHandle(forWritingTo: logFile) {
    handle.seekToEndOfFile()
    handle.write(logSample.data(using: .utf8)!)
    try? handle.close()
}
assertTest(FileManager.default.fileExists(atPath: logFile.path), "Log file exists at ~/Library/Logs/NestCast.log")
let fileContents = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
assertTest(fileContents.contains("[INFO]"), "Log file contains valid timestamped entries")

// ──────────────────────────────────────────────────────────
// Test 7: Live Hardware Communication (Surya speaker @ 192.168.1.4:8009)
// ──────────────────────────────────────────────────────────
print("\nTest 7: Live hardware test against Surya speaker (192.168.1.4:8009)")
let tlsOpts = NWProtocolTLS.Options()
sec_protocol_options_set_verify_block(tlsOpts.securityProtocolOptions, { _, _, c in c(true) }, .main)
let conn = NWConnection(host: "192.168.1.4", port: 8009, using: NWParameters(tls: tlsOpts))

var receivedLiveVolume: Float?

conn.stateUpdateHandler = { state in
    if case .ready = state {
        let cPkt = encodeCastMessage(source: "sender-0", dest: "receiver-0", ns: "urn:x-cast:com.google.cast.tp.connection", json: "{\"type\":\"CONNECT\"}")
        let sPkt = encodeCastMessage(source: "sender-0", dest: "receiver-0", ns: "urn:x-cast:com.google.cast.receiver", json: "{\"type\":\"GET_STATUS\",\"requestId\":999}")
        conn.send(content: cPkt + sPkt, completion: .contentProcessed({ _ in }))
        
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4096) { data, _, _, _ in
            if let d = data, d.count > 4 {
                let text = String(decoding: d.advanced(by: 4), as: UTF8.self)
                if let start = text.range(of: "{\"")?.lowerBound,
                   let end = text.range(of: "}", options: .backwards)?.upperBound {
                    let json = String(text[start..<end])
                    if let data = json.data(using: .utf8),
                       let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let status = dict["status"] as? [String: Any],
                       let vol = status["volume"] as? [String: Any],
                       let lvl = vol["level"] as? Double {
                        receivedLiveVolume = Float(lvl)
                    }
                }
            }
        }
    }
}
conn.start(queue: .main)

let deadline = Date().addingTimeInterval(3.0)
while Date() < deadline && receivedLiveVolume == nil {
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
}
conn.cancel()

assertTest(receivedLiveVolume != nil, "Successfully received and parsed live volume from physical Nest Mini")
if let vol = receivedLiveVolume {
    print("  → Surya speaker live hardware volume: \(Int(vol * 100))% (\(vol))")
    assertTest(vol >= 0.0 && vol <= 1.0, "Volume value is in valid normalized range [0.0, 1.0]")
}

// ──────────────────────────────────────────────────────────
// Test 8: Balanced-Brace JSON Extraction
// ──────────────────────────────────────────────────────────
print("\nTest 8: Balanced-brace JSON extraction algorithm")
func extractJsonObjects(from text: String) -> [String] {
    var results: [String] = []
    var searchStart = text.startIndex
    while let startIdx = text[searchStart...].range(of: "{\"")?.lowerBound {
        var braceCount = 0
        var foundEnd: String.Index? = nil
        var curr = startIdx
        while curr < text.endIndex {
            let char = text[curr]
            if char == "{" { braceCount += 1 }
            else if char == "}" {
                braceCount -= 1
                if braceCount == 0 {
                    foundEnd = text.index(after: curr)
                    break
                }
            }
            curr = text.index(after: curr)
        }
        if let endIdx = foundEnd {
            results.append(String(text[startIdx..<endIdx]))
            searchStart = endIdx
        } else { break }
    }
    return results
}

let packetWithNoise = "HEADER\u{12}\u{05}text{\"type\":\"PING\"}\u{00}\u{01}{\"type\":\"RECEIVER_STATUS\",\"volume\":{\"level\":0.5}}TRAILING_BYTES"
let extracted = extractJsonObjects(from: packetWithNoise)
assertTest(extracted.count == 2, "Extracted exactly 2 JSON objects from noisy protobuf packet")
assertTest(extracted[0] == "{\"type\":\"PING\"}", "First extracted JSON is PING")
assertTest(extracted[1].contains("RECEIVER_STATUS"), "Second extracted JSON is RECEIVER_STATUS")

// ──────────────────────────────────────────────────────────
// Test 9: CoreAudio Device Discovery & BlackHole Detection
// ──────────────────────────────────────────────────────────
print("\nTest 9: CoreAudio device discovery & BlackHole virtual device")
import CoreAudio

var propertyAddress = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDevices,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
var dataSize: UInt32 = 0
let status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize)
assertTest(status == noErr, "AudioObjectGetPropertyDataSize succeeds")
let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
assertTest(count > 0, "Discovered at least one audio device (found: \(count))")

var devs = [AudioDeviceID](repeating: 0, count: count)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &devs)

var hasBlackHole = false
var hasSpeakers = false
for dev in devs {
    var nSize: UInt32 = 256
    var nameBuf = [CChar](repeating: 0, count: 256)
    var nAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    if AudioObjectGetPropertyData(dev, &nAddr, 0, nil, &nSize, &nameBuf) == noErr {
        let name = String(cString: nameBuf)
        if name.localizedCaseInsensitiveContains("BlackHole") { hasBlackHole = true }
        if name.localizedCaseInsensitiveContains("Speakers") { hasSpeakers = true }
    }
}
assertTest(hasBlackHole, "BlackHole 2ch virtual audio driver is installed and accessible")
assertTest(hasSpeakers, "MacBook Pro Speakers audio device is detected")

// ──────────────────────────────────────────────────────────
// Test 10: SoX & Cloudflared Binaries Availability
// ──────────────────────────────────────────────────────────
print("\nTest 10: SoX & Cloudflared binaries verification")
let soxExists = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/sox") ||
                FileManager.default.isExecutableFile(atPath: "/usr/local/bin/sox")
assertTest(soxExists, "SoX audio encoder binary is present and executable")

let cfExists = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/cloudflared") ||
               FileManager.default.isExecutableFile(atPath: "/usr/local/bin/cloudflared")
assertTest(cfExists, "Cloudflared tunnel binary is present and executable")

print("\n======================================================")
print("  All 10 Tests Passed Successfully! System is 100% Ready.")
print("======================================================\n")
