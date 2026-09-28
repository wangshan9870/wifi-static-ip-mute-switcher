import CoreAudio

enum SpeakerAudio {
    static func read(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func internalSpeakers() -> [AudioDeviceID]? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return nil }
        guard size > 0 else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let result = devices.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!)
        }
        guard result == noErr else { return nil }
        return devices.prefix(Int(size) / MemoryLayout<AudioDeviceID>.size).filter {
            SpeakerPolicy.isInternalSpeaker(transport: read($0, kAudioDevicePropertyTransportType),
                source: read($0, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput))
        }
    }

    // Address the physical speaker even while headphones/HDMI are the default output.
    // Never change the default device, output volume, or any other device's mute state.
    static func setInternalSpeakersMuted(_ muted: Bool) -> (success: Bool, status: String) {
        guard let devices = internalSpeakers() else { return (false, "扬声器保护：读取音频设备失败，将重试") }
        guard !devices.isEmpty else { return (false, "扬声器保护：未识别到内置扬声器") }
        for device in devices {
            if read(device, kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput) == (muted ? 1 : 0) { continue }
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else {
                return (false, "扬声器保护：此设备不支持静音控制")
            }
            var mute: UInt32 = muted ? 1 : 0
            guard AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &mute) == noErr,
                  read(device, kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput) == mute else {
                return (false, "扬声器保护：声音切换失败，将重试")
            }
        }
        return (true, muted ? "扬声器保护：未确认在家 · 已静音" : "扬声器保护：在家 · 已取消静音")
    }
}
