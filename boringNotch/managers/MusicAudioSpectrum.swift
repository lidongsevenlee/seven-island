import AppKit
import AudioToolbox
import Combine
import CoreAudio

@MainActor
final class MusicAudioSpectrum: ObservableObject {
    static let shared = MusicAudioSpectrum()
    @Published private(set) var levels = [Float](repeating: 0, count: AudioSpectrumAnalyzer.bandCount)
    @Published private(set) var statusMessage: String?

    private var clients: [UUID: String] = [:]
    private var source: String?
    private let worker = MusicSpectrumWorker()
    private var generation = UUID()
    private var listeners: [(AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)] = []

    private init() {
        if #available(macOS 14.2, *) {
            for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyProcessObjectList] {
                var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                    Task { @MainActor in
                        guard let self, !self.clients.isEmpty else { return }
                        self.worker.refresh(force: selector == kAudioHardwarePropertyDefaultOutputDevice)
                    }
                }
                if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener) == noErr {
                    listeners.append((selector, listener))
                }
            }
        }
    }

    func setSource(_ bundleIdentifier: String?, for client: UUID) {
        clients[client] = bundleIdentifier?.isEmpty == false ? bundleIdentifier : nil
        reconcile()
    }

    func level(for column: Int, outOf count: Int) -> Float {
        let start = column * levels.count / count
        let end = (column + 1) * levels.count / count
        return levels[start..<end].max() ?? 0
    }

    func retry() { reconcile(force: true) }

    func openAudioPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            NSWorkspace.shared.open(url)
        }
    }

    private func reconcile(force: Bool = false) {
        let requested = clients.values.sorted().first
        guard force || requested != source else { return }
        generation = UUID()
        source = requested
        levels = [Float](repeating: 0, count: AudioSpectrumAnalyzer.bandCount)
        statusMessage = requested == nil ? nil : "连接播放器音频…"
        let token = generation
        worker.configure(source: requested, onLevels: { [weak self] incoming in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.levels = zip(self.levels, incoming).map { previous, target in
                    let weight: Float = target > previous ? 0.8 : 0.35
                    return previous + (target - previous) * weight
                }
                if incoming.contains(where: { $0 > 0.01 }) { self.statusMessage = nil }
            }
        }, onStatus: { [weak self] message in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.statusMessage = message
            }
        })
    }
}

private final class MusicSpectrumWorker {
    private let queue = DispatchQueue(label: "com.local.seven-island.music-capture", qos: .userInitiated)
    private var source: String?
    private var capture: MusicSpectrumCapture?
    private var onLevels: ([Float]) -> Void = { _ in }
    private var onStatus: (String?) -> Void = { _ in }

    func configure(source: String?, onLevels: @escaping ([Float]) -> Void, onStatus: @escaping (String?) -> Void) {
        queue.async {
            self.source = source
            self.onLevels = onLevels
            self.onStatus = onStatus
            self.restart()
        }
    }

    func refresh(force: Bool) {
        queue.async {
            guard self.source != nil else { return }
            if force || self.capture?.processesStillMatch() != true { self.restart() }
        }
    }

    private func restart() {
        capture?.stop()
        capture = nil
        guard let source else { onStatus(nil); return }
        guard #available(macOS 14.2, *) else {
            onStatus("实时律动需要 macOS 14.2 或更新版本")
            return
        }
        onStatus("连接播放器音频…")
        let next = ProcessMusicCapture(bundleIdentifier: source, onLevels: onLevels)
        do {
            try next.start()
            capture = next
            onStatus("等待播放器音频")
        } catch MusicCaptureError.noProcess {
            onStatus("等待播放器音频")
        } catch {
            onStatus("音频连接未就绪")
            NSLog("Music spectrum capture: %@", String(describing: error))
        }
    }
}

private protocol MusicSpectrumCapture: AnyObject {
    func stop()
    func processesStillMatch() -> Bool
}

private enum MusicCaptureError: Error {
    case noProcess
    case unsupportedFormat
    case audio(OSStatus)
}

@available(macOS 14.2, *)
private final class ProcessMusicCapture: MusicSpectrumCapture {
    private let bundleIdentifier: String
    private let onLevels: ([Float]) -> Void
    private let queue = DispatchQueue(label: "com.local.seven-island.music-spectrum", qos: .userInitiated)
    private var processIDs: [AudioObjectID] = []
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?

    init(bundleIdentifier: String, onLevels: @escaping ([Float]) -> Void) {
        self.bundleIdentifier = bundleIdentifier
        self.onLevels = onLevels
    }

    deinit { stop() }

    func start() throws {
        processIDs = Self.audioProcesses(for: bundleIdentifier)
        guard !processIDs.isEmpty else { throw MusicCaptureError.noProcess }
        let description = CATapDescription(stereoMixdownOfProcesses: processIDs)
        description.name = "Seven Island Music Spectrum"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        if #available(macOS 26.0, *) {
            description.bundleIDs = [bundleIdentifier]
            description.isProcessRestoreEnabled = true
        }
        do {
            try Self.check(AudioHardwareCreateProcessTap(description, &tapID))
            let tapUID = try Self.stringProperty(tapID, selector: kAudioTapPropertyUID)
            var format = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout.size(ofValue: format))
            var address = Self.address(kAudioTapPropertyFormat)
            try Self.check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format))
            guard format.mFormatID == kAudioFormatLinearPCM,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mBitsPerChannel == 32, format.mSampleRate > 0 else {
                throw MusicCaptureError.unsupportedFormat
            }

            // The aggregate's inputs contain the player's audio tap.
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Seven Island Music Spectrum",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true
                ]]
            ]
            try Self.check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceID))
            let processor = SpectrumBufferProcessor(sampleRate: format.mSampleRate, onLevels: onLevels)
            try Self.check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, deviceID, queue) { _, input, _, _, _ in
                processor.consume(input)
            })
            try Self.check(AudioDeviceStart(deviceID, ioProc))
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let ioProc {
            AudioDeviceStop(deviceID, ioProc)
            AudioDeviceDestroyIOProcID(deviceID, ioProc)
            self.ioProc = nil
        }
        if deviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(deviceID)
            deviceID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    func processesStillMatch() -> Bool {
        processIDs == Self.audioProcesses(for: bundleIdentifier)
    }

    private static func audioProcesses(for bundleIdentifier: String) -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard !objects.isEmpty else { return [] }
        let status = objects.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, bytes.baseAddress!)
        }
        guard status == noErr else { return [] }
        return objects.filter { object in
            guard let bundle = try? stringProperty(object, selector: kAudioProcessPropertyBundleID) else { return false }
            return bundle == bundleIdentifier || bundle.hasPrefix(bundleIdentifier + ".")
        }.sorted()
    }

    private static func stringProperty(_ object: AudioObjectID, selector: AudioObjectPropertySelector) throws -> String {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: value))
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value))
        guard let value else { throw MusicCaptureError.noProcess }
        return value.takeRetainedValue() as String
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func check(_ status: OSStatus) throws {
        if status != noErr { throw MusicCaptureError.audio(status) }
    }
}

final class SpectrumBufferProcessor {
    private let sampleRate: Double
    private let onLevels: ([Float]) -> Void
    private let analyzer = AudioSpectrumAnalyzer()
    private var channels = [[Float]](repeating: [Float](repeating: 0, count: AudioSpectrumAnalyzer.frameCount), count: 2)
    private var filled = 0
    private var samplesSinceAnalysis = 0

    init(sampleRate: Double, onLevels: @escaping ([Float]) -> Void) {
        self.sampleRate = sampleRate
        self.onLevels = onLevels
    }

    func consume(_ input: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        var sources: [(data: UnsafePointer<Float>, stride: Int, offset: Int, frames: Int)] = []
        for buffer in buffers {
            guard let data = buffer.mData, buffer.mNumberChannels > 0 else { continue }
            let stride = Int(buffer.mNumberChannels)
            let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / stride
            for channel in 0..<min(stride, 2 - sources.count) {
                sources.append((UnsafeRawPointer(data).assumingMemoryBound(to: Float.self), stride, channel, frames))
            }
            if sources.count == 2 { break }
        }
        guard let frameCount = sources.map(\.frames).min(), frameCount > 0 else { return }
        for frame in 0..<frameCount {
            for (channel, source) in sources.enumerated() {
                channels[channel][filled] = source.data[frame * source.stride + source.offset]
            }
            filled += 1
            if filled == AudioSpectrumAnalyzer.frameCount {
                filled = 0
                samplesSinceAnalysis += AudioSpectrumAnalyzer.frameCount
                if Double(samplesSinceAnalysis) / sampleRate >= 1.0 / 30 {
                    samplesSinceAnalysis = 0
                    onLevels(analyzer.levels(channels: Array(channels.prefix(sources.count)), sampleRate: sampleRate))
                }
            }
        }
    }
}
