import AppKit
import os

private let log = Log.keepAwake

/// 调暗和恢复：把屏幕亮度、键盘背光调到 0，可选把音量也调到 0，恢复时调回原值。
/// 只调亮度，不让屏幕熄灭：熄屏会触发锁屏，远程桌面也会看到锁屏界面。
final class Dimmer {
    /// 恢复失败时调用，参数是给用户看的错误信息。
    var onError: ((String) -> Void)?

    private let lid: LidMonitor
    private let keyboard = KeyboardBacklight()
    private var pausesPlayback = false
    private var isDimmed = false
    /// 当前调到原值的几成，1 是原样，0 是最低。渐变从这里出发，中途换方向也不会跳。
    private var level: Float = 1
    /// 调暗前的值一直保留到恢复完成。开盖后内置屏还没上线就又合盖时，读到的亮度已经是 0；
    /// 渐亮途中又调暗时，读到的是半路的值。所以已有记录时不重新读取。
    private var savedBrightness: Float?
    private var savedKeyboard: KeyboardBacklight.Snapshot?
    private var savedVolume: OutputVolume.Snapshot?
    /// 只在渐变时使用，见 DisplayGamma。
    private var savedGamma: DisplayGamma?
    private var fading: Fading?
    /// 开盖后正在等内置屏上线，见 fadeIn。
    private var isWaitingForDisplay = false
    private static let dimDuration: TimeInterval = 0.6
    private static let restoreDuration: TimeInterval = 0.6

    /// 正在渐变。期间向系统申明这是用户能看到的操作，免得软件被系统的节能调度（App Nap）挂起，
    /// 定时器被合并、推迟，画面一顿一顿的。
    private struct Fading {
        let timer: Timer
        let activity: NSObjectProtocol
    }

    init(lid: LidMonitor) {
        self.lid = lid
    }

    private var isRestoring: Bool {
        !isDimmed && (fading != nil || isWaitingForDisplay)
    }

    /// gradually 为 true 时用 0.6 秒逐渐调暗。盖子合着时屏幕和键盘看不见，直接调到 0，只有音量逐渐降低。
    /// pausesPlayback 为 true 时，调到最低后暂停正在播放的内容。
    func dim(gradually: Bool, lowersVolume: Bool, pausesPlayback: Bool) {
        if isDimmed {
            // 渐暗途中关掉了渐变：直接调到最低。
            if !gradually, fading != nil {
                finishDim()
            }
            return
        }
        isDimmed = true
        self.pausesPlayback = pausesPlayback
        stopFade()
        if savedBrightness == nil {
            savedBrightness = DisplayBrightness.get()
        }
        if savedKeyboard == nil {
            savedKeyboard = keyboard?.snapshot()
        }
        if lowersVolume, savedVolume == nil {
            savedVolume = OutputVolume.current()
            if savedVolume == nil {
                log.error("读取音量失败")
            }
        }
        if gradually {
            captureGamma()
            fade(to: 0, duration: Self.dimDuration, curve: Self.easeInOut) { [weak self] in self?.finishDim() }
        } else {
            finishDim()
        }
    }

    /// gradually 为 true 时用 0.6 秒逐渐恢复。
    func restore(gradually: Bool) {
        guard isDimmed || isRestoring || savedBrightness != nil else { return }
        if isRestoring, gradually {
            return
        }
        isDimmed = false
        if gradually {
            fadeIn(waitsLeft: 30)
        } else {
            finishRestore()
        }
    }

    /// 开盖后内置屏要过一会儿才重新上线。等它上线再开始渐亮，否则前半段调不了亮度，最后一下子亮起来。
    /// 每 0.1 秒看一次，最多等 3 秒；还没上线就照常渐亮，屏幕亮度交给 restoreDisplay 重试。
    private func fadeIn(waitsLeft: Int) {
        isWaitingForDisplay = false
        guard !isDimmed else { return }
        if DisplayBrightness.builtinDisplay() == nil, waitsLeft > 0 {
            isWaitingForDisplay = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.fadeIn(waitsLeft: waitsLeft - 1)
            }
            return
        }
        captureGamma()
        fade(to: 1, duration: Self.restoreDuration, curve: Self.easeOut) { [weak self] in self?.finishRestore() }
    }

    private func finishDim() {
        stopFade()
        apply(level: 0)
        // 背光已经是 0，画面恢复原样也看不见。稍等一下再恢复，确保背光已经降到底；
        // 这样调暗后的状态和直接调暗时一样，远程桌面看到的画面也正常。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, isDimmed else { return }
            restoreGamma()
        }
        if pausesPlayback {
            MediaPlayback.pause()
        }
        log.notice("已调暗")
    }

    private func finishRestore() {
        stopFade()
        level = 1
        restoreGamma()
        if let snapshot = savedKeyboard {
            keyboard?.apply(snapshot)
            savedKeyboard = nil
        }
        if let volume = savedVolume {
            if !OutputVolume.set(volume.volume, on: volume.device) {
                log.error("恢复音量失败")
            }
            savedVolume = nil
        }
        restoreDisplay(attemptsLeft: 10)
        log.notice("已恢复调暗前的亮度和音量")
    }

    /// 背光调到最低一档仍然看得见，到 0 又一下子全黑。渐变时同时按比例压暗画面，这一下就看不出来了。
    private func captureGamma() {
        guard savedGamma == nil, !lid.isClosed else { return }
        savedGamma = DisplayGamma.current()
        savedGamma?.apply(scale: level)
    }

    private func restoreGamma() {
        savedGamma?.apply(scale: 1)
        savedGamma = nil
    }

    /// 从当前程度渐变到 target。每秒调整的次数和屏幕刷新率一致（ProMotion 屏幕是 120 次），看不出台阶。
    private func fade(
        to target: Float,
        duration: TimeInterval,
        curve: @escaping (Double) -> Double,
        completion: @escaping () -> Void
    ) {
        stopFade()
        let from = level
        let start = Date()
        let framesPerSecond = NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 60
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "逐渐调整亮度"
        )
        let timer = Timer(timeInterval: 1 / Double(framesPerSecond), repeats: true) { [weak self] _ in
            let progress = min(Date().timeIntervalSince(start) / duration, 1)
            if progress < 1 {
                self?.apply(level: from + (target - from) * Float(curve(progress)))
            } else {
                completion()
            }
        }
        // 用 common 模式：打开菜单时定时器照常走。
        RunLoop.main.add(timer, forMode: .common)
        fading = Fading(timer: timer, activity: activity)
    }

    /// 两头慢、中间快：开始变暗和最后降到底时都不突兀。
    private static func easeInOut(_ progress: Double) -> Double {
        progress * progress * (3 - 2 * progress)
    }

    /// 先快后慢：一动鼠标马上就有反应。
    private static func easeOut(_ progress: Double) -> Double {
        1 - (1 - progress) * (1 - progress)
    }

    private func stopFade() {
        guard let fading else { return }
        fading.timer.invalidate()
        ProcessInfo.processInfo.endActivity(fading.activity)
        self.fading = nil
    }

    /// 按调暗前的值等比例调整。
    private func apply(level: Float) {
        self.level = level
        // 盖子合着时屏幕和键盘看不见，直接调到 0。之后内置屏会下线，再调亮度会失败，这是正常的。
        let closed = lid.isClosed
        let lightLevel = closed ? 0 : level
        let displayDone = savedBrightness.map { DisplayBrightness.set($0 * lightLevel) } ?? false
        savedGamma?.apply(scale: lightLevel)
        if let snapshot = savedKeyboard {
            keyboard?.apply(.init(brightness: snapshot.brightness * lightLevel, autoBrightness: false))
        }
        let volumeDone = savedVolume.map { OutputVolume.set($0.volume * level, on: $0.device) } ?? true
        // 渐变途中某一步失败不要紧，只在调到最低时记录。
        guard level == 0 else { return }
        if !displayDone, !closed {
            log.error("调低屏幕亮度失败")
        }
        if !volumeDone {
            log.error("调低音量失败")
        }
    }

    /// 开盖后内置屏要过一会儿才重新上线，所以每 0.5 秒重试一次。
    private func restoreDisplay(attemptsLeft: Int) {
        guard let brightness = savedBrightness else { return }
        if DisplayBrightness.set(brightness) {
            savedBrightness = nil
            return
        }
        guard attemptsLeft > 0 else {
            onError?("恢复屏幕亮度失败：内置屏一直未就绪")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !self.isDimmed, !self.lid.isClosed else { return }
            restoreDisplay(attemptsLeft: attemptsLeft - 1)
        }
    }
}
