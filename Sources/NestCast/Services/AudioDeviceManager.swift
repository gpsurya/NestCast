import Foundation
import CoreAudio
import AppKit

public final class AudioDeviceManager: ObservableObject, @unchecked Sendable {
    public static let shared = AudioDeviceManager()
    
    @Published public private(set) var isRedirectedToBlackHole: Bool = false
    private var originalDeviceID: AudioDeviceID?
    private let lock = NSLock()
    
    public init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
        
        // POSIX signal and exit handlers to guarantee output device restoration
        atexit {
            AudioDeviceManager.shared.restoreOriginalOutput()
        }
        
        signal(SIGINT) { _ in
            AudioDeviceManager.shared.restoreOriginalOutput()
            exit(0)
        }
        
        signal(SIGTERM) { _ in
            AudioDeviceManager.shared.restoreOriginalOutput()
            exit(0)
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        restoreOriginalOutput()
    }
    
    @objc private func handleAppWillTerminate() {
        restoreOriginalOutput()
    }
    
    public func getDeviceID(named match: String) -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize)
        guard status == noErr else { return nil }
        
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devs = [AudioDeviceID](repeating: 0, count: count)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &devs)
        
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
                if name.localizedCaseInsensitiveContains(match) {
                    return dev
                }
            }
        }
        return nil
    }
    
    public func getAllOutputDevices() -> [(id: AudioDeviceID, name: String)] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize)
        guard status == noErr else { return [] }
        
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devs = [AudioDeviceID](repeating: 0, count: count)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &devs)
        
        var outputs: [(id: AudioDeviceID, name: String)] = []
        for dev in devs {
            // Check if device has output streams
            var streamAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            if AudioObjectGetPropertyDataSize(dev, &streamAddr, 0, nil, &streamSize) == noErr && streamSize > 0 {
                var nSize: UInt32 = 256
                var nameBuf = [CChar](repeating: 0, count: 256)
                var nAddr = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyDeviceName,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                if AudioObjectGetPropertyData(dev, &nAddr, 0, nil, &nSize, &nameBuf) == noErr {
                    outputs.append((id: dev, name: String(cString: nameBuf)))
                }
            }
        }
        return outputs
    }
    
    public func getCurrentDefaultOutputDeviceID() -> AudioDeviceID? {
        var defaultDev: AudioDeviceID = 0
        var defSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var defAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defAddr, 0, nil, &defSize, &defaultDev)
        return st == noErr ? defaultDev : nil
    }
    
    @discardableResult
    public func setDefaultOutput(deviceID: AudioDeviceID) -> Bool {
        var target = deviceID
        var setAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let st = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &setAddr,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &target
        )
        return st == noErr
    }
    
    @discardableResult
    public func switchToBlackHole() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        guard let bhID = getDeviceID(named: "BlackHole") else {
            LogManager.shared.error("AudioDeviceManager", "BlackHole virtual audio driver not found. Please install via: brew install blackhole-2ch")
            return false
        }
        
        let current = getCurrentDefaultOutputDeviceID()
        if let cur = current, cur != bhID {
            originalDeviceID = cur
            LogManager.shared.audio("Saved original audio output device ID: \(cur)")
        }
        
        let success = setDefaultOutput(deviceID: bhID)
        if success {
            DispatchQueue.main.async {
                self.isRedirectedToBlackHole = true
            }
            LogManager.shared.audio("Redirected macOS Default Audio Output to BlackHole 2ch (ID: \(bhID))")
        } else {
            LogManager.shared.error("AudioDeviceManager", "Failed to switch default audio output to BlackHole 2ch")
        }
        return success
    }
    
    @discardableResult
    public func restoreOriginalOutput() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        let bhID = getDeviceID(named: "BlackHole")
        var targetID: AudioDeviceID? = originalDeviceID
        
        // If original device was not saved or is invalid, intelligently select best physical output
        if targetID == nil || targetID == bhID {
            let availableOutputs = getAllOutputDevices().filter { $0.id != bhID }
            // Prefer internal speakers or headphones
            if let preferred = availableOutputs.first(where: {
                $0.name.localizedCaseInsensitiveContains("Speakers") ||
                $0.name.localizedCaseInsensitiveContains("Headphones") ||
                $0.name.localizedCaseInsensitiveContains("Built-in")
            }) {
                targetID = preferred.id
            } else {
                targetID = availableOutputs.first?.id
            }
        }
        
        guard let tid = targetID else {
            LogManager.shared.error("AudioDeviceManager", "Unable to determine restore output audio device")
            return false
        }
        
        let success = setDefaultOutput(deviceID: tid)
        if success {
            originalDeviceID = nil
            DispatchQueue.main.async {
                self.isRedirectedToBlackHole = false
            }
            LogManager.shared.audio("Restored macOS Default Audio Output to device ID: \(tid)")
        } else {
            LogManager.shared.error("AudioDeviceManager", "Failed to restore audio output to device ID: \(tid)")
        }
        return success
    }
}
