import Foundation
import os

/// 系统级“禁止睡眠”（pmset disablesleep）。修改需要 root，
/// 首次授权时写入一条只允许这几条 pmset 命令免密执行的 sudoers 规则。
enum SleepSetting {
    struct AuthorizationCancelled: Error {}

    struct AuthorizationFailed: LocalizedError {
        let message: String
        var errorDescription: String? {
            "授权失败：\(message)"
        }
    }

    struct CommandError: LocalizedError {
        let command: String
        let status: Int32
        let output: String

        var errorDescription: String? {
            "\(command) 退出码 \(status)：\(output.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }

    /// 需要 root 的 pmset 命令。免密规则和实际执行都从这里生成，两边不会不一致。
    private enum RootCommand: CaseIterable {
        case allowSleep, disableSleep, sleepNow

        var arguments: [String] {
            switch self {
            case .allowSleep: ["-a", "disablesleep", "0"]
            case .disableSleep: ["-a", "disablesleep", "1"]
            case .sleepNow: ["sleepnow"]
            }
        }
    }

    private static let pmset = "/usr/bin/pmset"
    private static let sudoersPath = "/etc/sudoers.d/mactools"

    static var isAuthorized: Bool {
        FileManager.default.fileExists(atPath: sudoersPath)
    }

    static func authorize() throws {
        let user = NSUserName()
        guard user.range(of: "^[A-Za-z_][A-Za-z0-9_.-]*$", options: .regularExpression) != nil else {
            throw AuthorizationFailed(message: "用户名 \(user) 含有无法写入规则的字符")
        }
        let commands = RootCommand.allCases.map { ([pmset] + $0.arguments).joined(separator: " ") }
        let rule = "\(user) ALL=(root) NOPASSWD: \(commands.joined(separator: ", "))"
        // 先用 visudo 校验，通过后再放进 sudoers.d，避免写坏 sudo 配置。
        let shell = """
        f=$(/usr/bin/mktemp) && printf '%s\\n' '\(rule)' > "$f" && /usr/sbin/visudo -cf "$f" && \
        /usr/sbin/chown root:wheel "$f" && /bin/chmod 0440 "$f" && /bin/mv "$f" \(sudoersPath)
        """
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let prompt = "合盖运行需要修改系统睡眠设置的权限（只需授权一次）。"
        let source = "do shell script \"\(escaped)\" with prompt \"\(prompt)\" with administrator privileges"
        var errorInfo: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
        guard let errorInfo else { return }
        if errorInfo[NSAppleScript.errorNumber] as? Int == -128 {
            throw AuthorizationCancelled()
        }
        throw AuthorizationFailed(message: errorInfo[NSAppleScript.errorMessage] as? String ?? "\(errorInfo)")
    }

    static func setDisabled(_ disabled: Bool) throws {
        try runAsRoot(disabled ? .disableSleep : .allowSleep)
        Log.lidAwake.info("disablesleep=\(disabled)")
    }

    static func sleepNow() throws {
        try runAsRoot(.sleepNow)
    }

    private static func runAsRoot(_ command: RootCommand) throws {
        try run("/usr/bin/sudo", ["-n", pmset] + command.arguments)
    }

    @discardableResult
    private static func run(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw CommandError(command: ([path] + arguments).joined(separator: " "),
                               status: process.terminationStatus, output: output)
        }
        return output
    }
}
