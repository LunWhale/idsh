import HarnessISH
import AVFoundation
import BackgroundTasks
import UIKit

/// Keeps the process alive while iSH finishes booting in the background.
///
/// Two mechanisms are stacked:
///  - silent audio (works on iOS 18+, but is not a formal long-task grant);
///  - `BGContinuedProcessingTask` (iOS 26+, user-initiated, shows a Live
///    Activity and gives the scheduler an explicit reason to keep running).
@MainActor
final class BackgroundKeeper {
    static let shared = BackgroundKeeper()
    static let taskID = "com.brooks.idsh.continued.boot"

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var interruptionObserver: NSObjectProtocol?

    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var continuedTask: AnyObject?
    private var continuedSubmitted = false
    private var lastTitle = "idsh"
    private var lastSubtitle = "正在准备 DSH"
    private var lastProgress: Double = 0

    private init() {}

    func register() {
        guard #available(iOS 26.0, *) else { return }
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskID,
            using: .main
        ) { [weak self] task in
            guard let self, let continued = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.continuedTask = continued
            self.continuedSubmitted = true
            continued.expirationHandler = { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    // The system revoked the grant. The boot keeps running on
                    // the audio keep-alive; the extraction checkpoint makes a
                    // later kill resumable instead of fatal.
                    self.continuedTask = nil
                    self.continuedSubmitted = false
                    NSLog("idsh continued task expired")
                }
            }
            self.applyContinuedState()
        }
    }

    // MARK: - Silent audio

    func startAudio() {
        guard engine == nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            engine.attach(player)
            // Match the mixer's real output format. Scheduling a mono buffer on
            // a stereo output raises an ObjC exception (not catchable in Swift)
            // and kills the app the moment it enters background.
            let output = engine.mainMixerNode.outputFormat(forBus: 0)
            let sampleRate = output.sampleRate > 0 ? output.sampleRate : 44_100
            let channels = output.channelCount > 0 ? output.channelCount : 2
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels) else {
                NSLog("idsh audio keepalive: bad output format")
                return
            }
            engine.connect(player, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = 0.001
            let frames = AVAudioFrameCount(sampleRate)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
            try engine.start()
            player.play()
            self.engine = engine
            self.player = player
            observeInterruptions()
        } catch {
            NSLog("idsh audio keepalive failed: \(error.localizedDescription)")
        }
    }

    private func observeInterruptions() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            guard type == .ended else { return }
            Task { @MainActor in
                guard let self else { return }
                self.player?.stop()
                self.engine?.stop()
                self.player = nil
                self.engine = nil
                self.startAudio()
            }
        }
    }

    func stopAudio() {
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    // MARK: - Continued processing (iOS 26)

    /// Ask the scheduler for permission to keep working after the app leaves
    /// the foreground. Call while the app is still foregrounded.
    func submitContinued(title: String, subtitle: String, progress: Double = 0) {
        guard #available(iOS 26.0, *) else { return }
        lastTitle = title
        lastSubtitle = subtitle
        lastProgress = progress
        guard !continuedSubmitted else {
            updateContinued(title: title, subtitle: subtitle, progress: progress)
            return
        }
        let request = BGContinuedProcessingTaskRequest(
            identifier: Self.taskID,
            title: title,
            subtitle: subtitle
        )
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            continuedSubmitted = true
            NSLog("idsh continued task submitted")
        } catch {
            // Common when the app is already backgrounded or the identifier is
            // not registered. Audio + checkpointed extraction are the fallback.
            NSLog("idsh continued task submit failed: \(error.localizedDescription)")
        }
    }

    func updateContinued(title: String, subtitle: String, progress: Double) {
        lastTitle = title
        lastSubtitle = subtitle
        lastProgress = min(1, max(0, progress))
        applyContinuedState()
    }

    private func applyContinuedState() {
        guard #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask else { return }
        task.updateTitle(lastTitle, subtitle: lastSubtitle)
        task.progress.totalUnitCount = 1_000
        task.progress.completedUnitCount = Int64(lastProgress * 1_000)
    }

    func finishContinued(success: Bool) {
        guard #available(iOS 26.0, *) else { return }
        if #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask {
            applyContinuedState()
            task.setTaskCompleted(success: success)
        }
        continuedTask = nil
        continuedSubmitted = false
    }

    // MARK: - Short background grace

    /// ~30 seconds to hand off from the foreground scene to the continued task.
    func beginBackgroundExecution() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "idsh.boot") { [weak self] in
            Task { @MainActor in self?.endBackgroundExecution() }
        }
    }

    func endBackgroundExecution() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
