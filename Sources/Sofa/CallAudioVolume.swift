import AudioToolbox
import Foundation

/// Applies gain to FaceTime's outgoing audio without changing the movie or the
/// Mac output volume. Core Audio's process tap mutes only the tapped source
/// while it is being read; Sofa immediately writes the scaled samples back to
/// the same physical output. Samples are never stored or sent over the network.
@available(macOS 14.2, *)
final class CallAudioVolume: @unchecked Sendable {
    static let shared = CallAudioVolume()

    private let queue = DispatchQueue(label: "sofa.call-audio", qos: .userInitiated)
    private var gain: Float = 1
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    private init() {}

    func set(percent: Double, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        let target = Float(max(0, min(100, percent)) / 100)
        queue.async { [self] in
            gain = target
            if target >= 0.995 {
                stopLocked()
                DispatchQueue.main.async { completion(.success(())) }
                return
            }

            do {
                if tapID == kAudioObjectUnknown { try startLocked() }
                DispatchQueue.main.async { completion(.success(())) }
            } catch {
                stopLocked()
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func stop() {
        queue.async { [self] in
            gain = 1
            stopLocked()
        }
    }

    private func startLocked() throws {
        let processIDs = try faceTimeAudioProcesses()
        if #unavailable(macOS 26.0), processIDs.isEmpty {
            throw CallAudioError.noFaceTimeAudio
        }

        let tap = CATapDescription(stereoMixdownOfProcesses: processIDs)
        tap.uuid = UUID()
        tap.name = "Sofa FaceTime volume"
        tap.isPrivate = true
        tap.muteBehavior = .mutedWhenTapped
        if #available(macOS 26.0, *) {
            // Bundle matching also follows FaceTime's private conversation XPC
            // service and survives the service restarting between calls.
            tap.bundleIDs = [
                "com.apple.FaceTime",
                "com.apple.FaceTime.FTConversationService",
            ]
            tap.isProcessRestoreEnabled = true
        }

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(tap, &newTapID), "create the FaceTime audio tap")
        tapID = newTapID

        let tapFormat = try audioFormat(
            of: tapID,
            selector: kAudioTapPropertyFormat,
            scope: kAudioObjectPropertyScopeGlobal
        )
        guard tapFormat.isFloat32PCM else { throw CallAudioError.unsupportedFormat }

        let outputDevice = try defaultOutputDevice()
        let outputUID = try stringProperty(
            of: outputDevice,
            selector: kAudioDevicePropertyDeviceUID
        )
        let aggregateUID = "com.pablo.sofa.call-audio.\(UUID().uuidString)"
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Sofa FaceTime volume",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tap.uuid.uuidString,
                ]
            ],
        ]

        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        try check(
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregateID),
            "create the private audio device"
        )
        aggregateDeviceID = newAggregateID

        let outputFormat = try audioFormat(
            of: aggregateDeviceID,
            selector: kAudioDevicePropertyStreamFormat,
            scope: kAudioDevicePropertyScopeOutput
        )
        guard outputFormat.isFloat32PCM else { throw CallAudioError.unsupportedFormat }

        let ioBlock: AudioDeviceIOBlock = { [weak self] _, inputData, _, outputData, _ in
            guard let self else { return }
            self.render(input: inputData, output: outputData)
        }
        var newIOProcID: AudioDeviceIOProcID?
        try check(
            AudioDeviceCreateIOProcIDWithBlock(
                &newIOProcID,
                aggregateDeviceID,
                queue,
                ioBlock
            ),
            "start the FaceTime volume processor"
        )
        ioProcID = newIOProcID
        try check(
            AudioDeviceStart(aggregateDeviceID, ioProcID),
            "start FaceTime audio"
        )
    }

    /// Core Audio calls this block on `queue`, the same serial queue used for
    /// slider updates and teardown. No lock or allocation occurs in real time.
    private func render(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>
    ) {
        let inputs = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: input)
        )
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        for index in outputs.indices {
            guard let outData = outputs[index].mData else { continue }
            memset(outData, 0, Int(outputs[index].mDataByteSize))
        }

        if inputs.count == outputs.count {
            for index in inputs.indices {
                scaleMatching(input: inputs[index], output: &outputs[index])
            }
            return
        }

        // HAL commonly exposes a stereo tap as one interleaved buffer and the
        // physical output as two mono buffers (or the inverse).
        if inputs.count == 1, inputs[0].mNumberChannels == 2,
           outputs.count >= 2,
           outputs[0].mNumberChannels == 1, outputs[1].mNumberChannels == 1 {
            guard let source = inputs[0].mData?.assumingMemoryBound(to: Float.self),
                  let left = outputs[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = outputs[1].mData?.assumingMemoryBound(to: Float.self) else { return }
            let frames = min(
                Int(inputs[0].mDataByteSize) / (MemoryLayout<Float>.size * 2),
                min(
                    Int(outputs[0].mDataByteSize) / MemoryLayout<Float>.size,
                    Int(outputs[1].mDataByteSize) / MemoryLayout<Float>.size
                )
            )
            for frame in 0..<frames {
                left[frame] = source[frame * 2] * gain
                right[frame] = source[frame * 2 + 1] * gain
            }
            return
        }

        if inputs.count >= 2,
           inputs[0].mNumberChannels == 1, inputs[1].mNumberChannels == 1,
           outputs.count == 1, outputs[0].mNumberChannels == 2 {
            guard let left = inputs[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = inputs[1].mData?.assumingMemoryBound(to: Float.self),
                  let destination = outputs[0].mData?.assumingMemoryBound(to: Float.self) else { return }
            let frames = min(
                Int(outputs[0].mDataByteSize) / (MemoryLayout<Float>.size * 2),
                min(
                    Int(inputs[0].mDataByteSize) / MemoryLayout<Float>.size,
                    Int(inputs[1].mDataByteSize) / MemoryLayout<Float>.size
                )
            )
            for frame in 0..<frames {
                destination[frame * 2] = left[frame] * gain
                destination[frame * 2 + 1] = right[frame] * gain
            }
        }
    }

    private func scaleMatching(input: AudioBuffer, output: inout AudioBuffer) {
        guard input.mNumberChannels == output.mNumberChannels,
              let source = input.mData?.assumingMemoryBound(to: Float.self),
              let destination = output.mData?.assumingMemoryBound(to: Float.self) else { return }
        let samples = min(Int(input.mDataByteSize), Int(output.mDataByteSize))
            / MemoryLayout<Float>.size
        for sample in 0..<samples { destination[sample] = source[sample] * gain }
    }

    private func stopLocked() {
        if aggregateDeviceID != kAudioObjectUnknown {
            _ = AudioDeviceStop(aggregateDeviceID, ioProcID)
            if let ioProcID {
                _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            }
            ioProcID = nil
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func faceTimeAudioProcesses() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
            ),
            "read running audio processes"
        )
        var values = [AudioObjectID](
            repeating: AudioObjectID(kAudioObjectUnknown),
            count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        try check(
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &values
            ),
            "read running audio processes"
        )
        return values.filter { objectID in
            guard let bundleID = try? stringProperty(
                of: objectID,
                selector: kAudioProcessPropertyBundleID
            ) else { return false }
            return bundleID == "com.apple.FaceTime" || bundleID.contains("FaceTime")
        }
    }

    private func defaultOutputDevice() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        try check(
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &value
            ),
            "find the current speakers"
        )
        guard value != kAudioObjectUnknown else { throw CallAudioError.noOutput }
        return value
    }

    private func stringProperty(
        of objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        try check(
            withUnsafeMutablePointer(to: &value) {
                AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, $0)
            },
            "read an audio property"
        )
        return value as String
    }

    private func audioFormat(
        of objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value),
            "read the audio format"
        )
        return value
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw CallAudioError.coreAudio(operation, status) }
    }
}

private extension AudioStreamBasicDescription {
    var isFloat32PCM: Bool {
        mFormatID == kAudioFormatLinearPCM &&
            (mFormatFlags & kAudioFormatFlagIsFloat) != 0 &&
            mBitsPerChannel == 32
    }
}

private enum CallAudioError: LocalizedError {
    case noFaceTimeAudio
    case noOutput
    case unsupportedFormat
    case coreAudio(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .noFaceTimeAudio:
            return "FaceTime is not sending audio yet. Start the call and try again."
        case .noOutput:
            return "Sofa could not find the current audio output."
        case .unsupportedFormat:
            return "This audio device does not support independent FaceTime volume yet."
        case .coreAudio(let operation, let status):
            return "Sofa could not \(operation) (Core Audio \(status))."
        }
    }
}
