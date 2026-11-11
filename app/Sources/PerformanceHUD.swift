import SwiftUI
import UIKit
import Darwin.Mach

/// Lightweight, Xcode-style performance overlay. It intentionally reads only
/// public process/machine counters so it can ship in a sideloaded IPA.
@MainActor
final class PerformanceMonitor: ObservableObject {
    static let shared = PerformanceMonitor()

    @Published var fps = 0
    @Published var cpuPercent = 0.0
    @Published var memoryMB = 0.0
    @Published var thermal = "nominal"
    @Published var battery = -1.0
    @Published var lowPower = false

    private var link: CADisplayLink?
    private var timer: Timer?
    private var frames = 0
    private var lastCPU: Double = -1
    private var lastSample = Date()

    private init() {}

    func start() {
        guard link == nil else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        let displayLink = CADisplayLink(target: self, selector: #selector(tick))
        displayLink.add(to: .main, forMode: .common)
        link = displayLink
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        lastSample = Date()
        lastCPU = Self.cpuSeconds()
    }

    func stop() {
        link?.invalidate()
        link = nil
        timer?.invalidate()
        timer = nil
    }

    @objc private func tick() {
        frames += 1
    }

    private func sample() {
        let now = Date()
        let dt = max(0.001, now.timeIntervalSince(lastSample))
        lastSample = now

        fps = Int(Double(frames) / dt)
        frames = 0

        let cpu = Self.cpuSeconds()
        if cpu >= 0, lastCPU >= 0, dt > 0 {
            cpuPercent = min(100, max(0, (cpu - lastCPU) / dt * 100))
        }
        lastCPU = cpu
        memoryMB = Self.residentMB()

        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        battery = Double(UIDevice.current.batteryLevel)
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    private static func cpuSeconds() -> Double {
        var info = task_thread_times_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_thread_times_info>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_THREAD_TIMES_INFO),
                    rebound,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        let user = Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1_000_000
        let system = Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1_000_000
        return user + system
    }

    private static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    rebound,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / 1024 / 1024
    }
}

struct PerformanceHUDView: View {
    @ObservedObject private var monitor = PerformanceMonitor.shared
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text("\(monitor.fps) FPS")
                Text(String(format: "%.0f MB", monitor.memoryMB))
                Text("thermal \(monitor.thermal)")
            }
            if expanded {
                HStack(spacing: 8) {
                    Text(monitor.lowPower ? "low-power" : "normal")
                    Text(monitor.battery >= 0 ? "\(Int(monitor.battery * 100))%" : "battery ?")
                }
            }
        }
        .font(.system(size: 9, weight: .medium, design: .monospaced))
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(.white.opacity(0.14)))
        .onTapGesture { expanded.toggle() }
        .onAppear { monitor.start() }
    }
}
