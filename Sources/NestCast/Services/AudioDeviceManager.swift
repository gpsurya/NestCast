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
    }
    
    deinit {
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
            LogManager.shared.error("AudioDeviceManager", "BlackHole virtual audio device not found")
            return false
        }
        
        let current = getCurrentDefaultOutputDeviceID()
        if current != bhID {
            originalDeviceID = current
        }
        
        let success = setDefaultOutput(deviceID: bhID)
        if success {
            DispatchQueue.main.async {
                self.isRedirectedToBlackHole = true
            }
            LogManager.shared.audio("Successfully redirected macOS Default Audio Output to BlackHole 2ch (ID: \(bhID))")
        } else {
            LogManager.shared.error("AudioDeviceManager", "Failed to switch default audio output to BlackHole 2ch")
        }
        return success
    }
    
    @discardableResult
    public func restoreOriginalOutput() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        var targetID: AudioDeviceID? = originalDeviceID
        if targetID == nil {
            targetID = getDeviceID(named: "Speakers")
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
