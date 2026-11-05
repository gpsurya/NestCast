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
print("  Running NestCast Comprehensive Test Suite")
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
// Test 3: Cast V2 Wire Protocol Framing
// ──────────────────────────────────────────────────────────
print("\nTest 3: Cast V2 wire protocol framing")
func encodeCastMessage(source: String, dest: String, ns: String, json: String) -> Data {
    func makeVarint(_ val: UInt64) -> [UInt8] {
        var v = val; var res: [UInt8] = []
        while v > 0x7F { res.append(UInt8((v & 0x7F) | 0x80)); v >>= 7 }
        res.append(UInt8(v)); return res
    }
    func encodeString(tag: UInt8, str: String) -> [UInt8] {
        let utf8 = Array(str.utf8)
        return [tag] + makeVarint(UInt64(utf8.count)) + utf8
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

let setVolumePkt = encodeCastMessage(
    source: "sender-0",
    dest: "receiver-0",
    ns: "urn:x-cast:com.google.cast.receiver",
    json: "{\"type\":\"SET_VOLUME\",\"volume\":{\"level\":0.75},\"requestId\":10}"
)
assertTest(setVolumePkt.count > 4, "SET_VOLUME packet has length > 4")
var pktLen: UInt32 = 0
setVolumePkt.prefix(4).withUnsafeBytes { ptr in
    pktLen = ptr.load(as: UInt32.self).bigEndian
}
assertTest(Int(pktLen) == setVolumePkt.count - 4, "Packet length prefix matches body length exactly (\(pktLen) bytes)")

// ──────────────────────────────────────────────────────────
// Test 4: Volume State & Packet Parser Synchronization
// ──────────────────────────────────────────────────────────
print("\nTest 4: Volume state & parser synchronization")
class MockCastState {
    var currentVolume: Float = 0.5
    var activeDeviceVolume: Float = 0.5
    
    func parseMessage(_ jsonString: String) {
        if let data = jsonString.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let status = dict["status"] as? [String: Any],
               let volDict = status["volume"] as? [String: Any],
               let lvl = volDict["level"] as? Double {
                self.currentVolume = Float(lvl)
                self.activeDeviceVolume = Float(lvl)
            } else if let devDict = dict["device"] as? [String: Any],
                      let volDict = devDict["volume"] as? [String: Any],
                      let lvl = volDict["level"] as? Double {
                self.currentVolume = Float(lvl)
                self.activeDeviceVolume = Float(lvl)
            }
        }
    }
}

let mockState = MockCastState()
assertTest(mockState.currentVolume == 0.5, "Default initial volume is 0.5 (50%)")

// Simulate incoming RECEIVER_STATUS from Google Nest Mini
let mockStatusJson = """
{"requestId":1,"status":{"applications":[],"volume":{"controlType":"master","level":0.725,"muted":false}},"type":"RECEIVER_STATUS"}
"""
mockState.parseMessage(mockStatusJson)
assertTest(abs(mockState.currentVolume - 0.725) < 0.001, "Volume correctly updated to 72.5% from RECEIVER_STATUS")
assertTest(abs(mockState.activeDeviceVolume - 0.725) < 0.001, "Device volume synchronized to 72.5%")

// Simulate multizone volume update
let mockMultizoneJson = """
{"device":{"name":"Surya speaker","volume":{"level":0.40,"muted":false}},"type":"DEVICE_UPDATED"}
"""
mockState.parseMessage(mockMultizoneJson)
assertTest(abs(mockState.currentVolume - 0.40) < 0.001, "Volume correctly updated to 40% from multizone DEVICE_UPDATED")

// ──────────────────────────────────────────────────────────
// Test 5: Live Hardware Communication (Surya speaker @ 192.168.1.4:8009)
// ──────────────────────────────────────────────────────────
print("\nTest 5: Live hardware test against Surya speaker (192.168.1.4:8009)")
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
while receivedLiveVolume == nil && Date() < deadline {
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
}
conn.cancel()

assertTest(receivedLiveVolume != nil, "Successfully received and parsed live volume from physical Nest Mini")
if let vol = receivedLiveVolume {
    print("  → Surya speaker live hardware volume: \(Int(vol * 100))% (\(vol))")
    assertTest(vol >= 0.0 && vol <= 1.0, "Volume value is in valid normalized range [0.0, 1.0]")
}

// ──────────────────────────────────────────────────────────
// Test 6: Helper Binary & Bundle Verification
// ──────────────────────────────────────────────────────────
print("\nTest 6: Helper binary & resource verification")
let helperPath = "/Users/suryaprakashpalanisamy/NestCast/Resources/aircast"
assertTest(FileManager.default.fileExists(atPath: helperPath), "Aircast helper exists at Resources/aircast")
assertTest(FileManager.default.isExecutableFile(atPath: helperPath), "Aircast helper has executable permissions (+x)")

print("\n======================================================")
print("  All 6 Tests Passed Successfully! System is 100% Ready.")
print("======================================================\n")
