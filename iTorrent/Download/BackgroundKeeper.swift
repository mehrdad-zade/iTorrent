import AVFoundation
import BackgroundTasks
import UIKit

/// Keeps downloads running while the app is in the background.
///
/// 1. `BGContinuedProcessingTask` (iOS 26): one per user-started download, with system progress UI.
///    If the user cancels it there (or iOS expires it), that download is stopped.
/// 2. Optional silent-audio keepalive (Settings, sideload builds only) for unlimited background time.
/// 3. A `beginBackgroundTask` bridge while the app is transitioning to the background.
///
/// No iOS mechanism survives a force-quit. libtorrent's resume data restarts downloads on next launch.
final class BackgroundKeeper {
    static let shared = BackgroundKeeper()
    static let silentAudioKey = "silentAudioKeepAlive"

    /// Called when the system ends a download's continued-processing task (user cancel or expiry).
    var onExpired: ((String) -> Void)?

    private let taskPrefix = (Bundle.main.bundleIdentifier ?? "itorrent") + ".download."
    private var registered: Set<String> = []
    private var tasks: [String: BGContinuedProcessingTask] = [:]
    private var transitionTask: UIBackgroundTaskIdentifier = .invalid
    private var keepAliveRequested = false
    private let audio = SilentAudio()

    private init() {
        UserDefaults.standard.register(defaults: [Self.silentAudioKey: true])
    }

    // MARK: Continued processing tasks

    func begin(hash: String, title: String) {
        guard tasks[hash] == nil else { return }
        let identifier = taskPrefix + hash
        if !registered.contains(identifier) {
            let didRegister = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) {
                @Sendable [weak self] task in
                // Delivered on the main queue (see `using: .main`), so handing it to the main actor is safe.
                nonisolated(unsafe) let task = task
                MainActor.assumeIsolated {
                    guard let task = task as? BGContinuedProcessingTask else { return task.setTaskCompleted(success: false) }
                    self?.attach(task, hash: hash)
                }
            }
            guard didRegister else { return print("BGTask register failed for \(identifier)") }
            registered.insert(identifier)
        }

        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: "Starting download…")
        request.strategy = .queue
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("BGContinuedProcessingTask submit failed: \(error)")
        }
    }

    private func attach(_ task: BGContinuedProcessingTask, hash: String) {
        tasks[hash] = task
        task.progress.totalUnitCount = 1000
        task.expirationHandler = { @Sendable [weak self] in
            Task { @MainActor in
                guard let self, let task = self.tasks.removeValue(forKey: hash) else { return }
                task.setTaskCompleted(success: false)
                self.onExpired?(hash)
            }
        }
    }

    func update(hash: String, progress: Double, rate: UInt64) {
        guard let task = tasks[hash] else { return }
        task.progress.completedUnitCount = Int64(progress * 1000)
        let speed = ByteCountFormatter.string(fromByteCount: Int64(rate), countStyle: .binary)
        task.updateTitle(task.title, subtitle: "\(Int(progress * 100))% · \(speed)/s")
    }

    func end(hash: String, success: Bool) {
        tasks.removeValue(forKey: hash)?.setTaskCompleted(success: success)
    }

    // MARK: Silent-audio keepalive

    func setKeepAlive(_ active: Bool) {
        keepAliveRequested = active
        applyKeepAlive()
    }

    func applyKeepAlive() {
        let enabled = UserDefaults.standard.bool(forKey: Self.silentAudioKey)
        if keepAliveRequested && enabled { audio.start() } else { audio.stop() }
    }

    // MARK: App lifecycle

    func didEnterBackground() {
        guard transitionTask == .invalid else { return }
        transitionTask = UIApplication.shared.beginBackgroundTask(withName: "torrent-handoff") { [weak self] in
            self?.endTransitionTask()
        }
    }

    func willEnterForeground() {
        endTransitionTask()
    }

    private func endTransitionTask() {
        guard transitionTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(transitionTask)
        transitionTask = .invalid
    }
}

/// Plays silence through AVAudioEngine so the `audio` background mode keeps the process alive.
private final class SilentAudio {
    private let engine = AVAudioEngine()
    private var isRunning = false
    private var observers: [NSObjectProtocol] = []

    init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let node = Self.makeSilentNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0

        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { @Sendable [weak self] note in
            let ended = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init) == .ended
            guard ended else { return }
            MainActor.assumeIsolated { self?.restartIfNeeded() }
        })
    }

    // Built outside the main actor: the render block runs on the real-time audio thread.
    private nonisolated static func makeSilentNode() -> AVAudioSourceNode {
        AVAudioSourceNode { _, _, _, bufferList in
            for buffer in UnsafeMutableAudioBufferListPointer(bufferList) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            return noErr
        }
    }

    func start() {
        guard !isRunning else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
            isRunning = true
        } catch {
            print("Silent audio failed to start: \(error)")
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isRunning = false
    }

    private func restartIfNeeded() {
        guard isRunning else { return }
        isRunning = false
        start()
    }
}
