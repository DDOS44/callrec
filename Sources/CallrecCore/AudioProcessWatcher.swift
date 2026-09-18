import CoreAudio
import Foundation

public struct AudioProcessInfo {
    public let objectID: AudioObjectID
    public let pid: pid_t
    public let bundleID: String
    public let isRunningOutput: Bool
    public let isRunningInput: Bool

    public init(objectID: AudioObjectID, pid: pid_t, bundleID: String, isRunningOutput: Bool, isRunningInput: Bool) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.isRunningOutput = isRunningOutput
        self.isRunningInput = isRunningInput
    }
}

public enum AudioProcessWatcher {
    public static func snapshot() throws -> [AudioProcessInfo] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size))
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids))
        return ids.map { id in
            AudioProcessInfo(objectID: id,
                             pid: (try? readPID(id)) ?? -1,
                             bundleID: (try? readString(id, kAudioProcessPropertyBundleID)) ?? "",
                             isRunningOutput: (try? readBool(id, kAudioProcessPropertyIsRunningOutput)) ?? false,
                             isRunningInput: (try? readBool(id, kAudioProcessPropertyIsRunningInput)) ?? false)
        }
    }

    private static func readPID(_ id: AudioObjectID) throws -> pid_t {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var v: pid_t = 0; var size = UInt32(MemoryLayout<pid_t>.size)
        try check(AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v)); return v
    }

    private static func readBool(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) throws -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var v: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
        try check(AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v)); return v != 0
    }

    private static func readString(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) throws -> String {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var v: Unmanaged<CFString>? = nil; var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v))
        return v?.takeRetainedValue() as String? ?? ""
    }

    public static func check(_ s: OSStatus) throws {
        if s != noErr {
            throw NSError(domain: "CoreAudio", code: Int(s), userInfo: [NSLocalizedDescriptionKey: "CoreAudio error \(s)"])
        }
    }
}
