import Foundation
import os

private let log = Log.keepAwake

/// 暂停正在播放的内容。命令通过系统私有的 MediaRemote 框架发出，效果和键盘上的播放/暂停键一样，
/// 但只会暂停：没在播放时发出去不会有任何反应，不会反过来把音乐打开。
enum MediaPlayback {
    private typealias SendCommand = @convention(c) (UInt32, CFDictionary?) -> Bool

    /// MRMediaRemoteCommand 里“暂停”的取值。
    private static let pauseCommand: UInt32 = 1

    private static let sendCommand = dlsym(
        dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW),
        "MRMediaRemoteSendCommand"
    ).map { unsafeBitCast($0, to: SendCommand.self) }

    static func pause() {
        guard let sendCommand, sendCommand(pauseCommand, nil) else {
            log.error("发送暂停命令失败")
            return
        }
    }
}
