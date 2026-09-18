import Foundation

/// Checks and requests system-audio recording permission via the private TCC SPI.
/// Mirrors insidegui/AudioCap's AudioRecordingPermission.swift (MIT).
public enum AudioRecordingPermission {

    public enum Status: String {
        case unknown, denied, authorized
    }

    private static let service = "kTCCServiceAudioCapture" as CFString

    private typealias PreflightFuncType = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFuncType = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

    private static let apiHandle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    private static let preflightSPI: PreflightFuncType? = {
        guard let apiHandle, let sym = dlsym(apiHandle, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(sym, to: PreflightFuncType.self)
    }()

    private static let requestSPI: RequestFuncType? = {
        guard let apiHandle, let sym = dlsym(apiHandle, "TCCAccessRequest") else { return nil }
        return unsafeBitCast(sym, to: RequestFuncType.self)
    }()

    public static var status: Status {
        guard let preflightSPI else { return .unknown }
        switch preflightSPI(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Triggers the system prompt if permission has not been decided yet.
    /// Blocks for up to `timeout` seconds waiting for the user to answer.
    @discardableResult
    public static func request(timeout: TimeInterval = 60) -> Status {
        if status == .authorized { return .authorized }
        guard let requestSPI else { return status }
        let sem = DispatchSemaphore(value: 0)
        requestSPI(service, nil) { _ in sem.signal() }
        _ = sem.wait(timeout: .now() + timeout)
        return status
    }

    public static let deniedMessage = "No system-audio permission. Open System Settings -> Privacy & Security -> Screen & System Audio Recording and enable this app (or Terminal), then rerun."
}
