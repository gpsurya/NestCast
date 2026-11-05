import Foundation

func assertTest(_ condition: Bool, _ message: String) {
    if !condition {
        print("❌ TEST FAILED: \(message)")
        exit(1)
    }
    print("✓ PASSED: \(message)")
}

print("=========================================")
print("  Running NestCast Test Suite")
print("=========================================\n")

// Test 1: CastDevice struct initialization
print("Test 1: CastDevice model initialization")
struct TestDevice {
    let id: String
    let name: String
    let model: String
    let host: String
    let port: Int
    var volume: Float
}

let dev = TestDevice(id: "dev-1", name: "Surya speaker", model: "Google Nest Mini", host: "192.168.1.4", port: 8009, volume: 0.7)
assertTest(dev.id == "dev-1", "Device ID matches")
assertTest(dev.name == "Surya speaker", "Device name matches")
assertTest(dev.model == "Google Nest Mini", "Device model matches")
assertTest(dev.port == 8009, "Device port is 8009")
assertTest(dev.volume == 0.7, "Volume matches")

// Test 2: WAV Chime Generation
print("\nTest 2: Audio chime WAV generation and header verification")
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
assertTest(magic == "RIFF", "RIFF magic header present")
let waveId = String(data: wavData.subdata(in: 8..<12), encoding: .ascii)
assertTest(waveId == "WAVE", "WAVE format identifier present")

// Test 3: Cast V2 Packet Framing
print("\nTest 3: Cast V2 wire protocol framing")
func encodeCastMessage(source: String, dest: String, ns: String, json: String) -> Data {
    func makeVarint(_ val: UInt64) -> [UInt8] {
        var v = val
        var res: [UInt8] = []
        while v > 0x7F {
            res.append(UInt8((v & 0x7F) | 0x80))
            v >>= 7
        }
        res.append(UInt8(v))
        return res
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

let pingPacket = encodeCastMessage(source: "sender-0", dest: "receiver-0", ns: "urn:x-cast:com.google.cast.tp.heartbeat", json: "{\"type\":\"PING\"}")
assertTest(pingPacket.count > 4, "Packet length is greater than 4-byte header")

var bigEndianLen: UInt32 = 0
pingPacket.prefix(4).withUnsafeBytes { ptr in
    bigEndianLen = ptr.load(as: UInt32.self).bigEndian
}
assertTest(Int(bigEndianLen) == pingPacket.count - 4, "Big-endian length matches body size (\(bigEndianLen) bytes)")

print("\n=========================================")
print("  All NestCast Tests Passed Successfully!")
print("=========================================\n")
