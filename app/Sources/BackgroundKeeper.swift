import HarnessISH
import AVFoundation
import BackgroundTasks
import UIKit

@MainActor
final class BackgroundKeeper {
    static let shared = BackgroundKeeper()
    static let taskID = "com.brooks.idsh.continued.main"

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var pendingTask: BGTask?
    private var interruptionObserver: NSObjectProtocol?

    private init() {}

    func register() {
        guard #available(iOS 26.0, *) else { return }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskID, using: .main) { [weak self] task in
            self?.pendingTask = task
            task.expirationHandler = { [weak self] in
                self?.pendingTask = nil
            }
        }
    }

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

    func submitContinued() {
        guard #available(iOS 26.0, *) else { return }
        let request = BGContinuedProcessingTaskRequest(
            identifier: Self.taskID,
            title: "idsh",
            subtitle: "DSH 正在后台运行"
        )
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            NSLog("idsh continued task submit failed: \(error.localizedDescription)")
        }
    }
}
