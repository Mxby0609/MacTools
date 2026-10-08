import Foundation

/// 系统级“禁止睡眠”（pmset disablesleep）。修改需要 root，
/// 首次授权时写入一条只允许这几条 pmset 命令免密执行的 sudoers 规则。
enum SleepSetting {
    struct AuthorizationCancelled: Error {}

    struct AuthorizationFailed: LocalizedError {
        let message: String
        var errorDescription: String? { "授权失败：\(message)" }
    }

    static let sudoersPath = "/etc/sudoers.d/lidawake"

    static var isAuthorized: Bool {
        FileManager.default.fileExists(atPath: sudoersPath)
    }

    static func authorize() throws {
        let user = NSUserName()
        guard user.range(of: "^[A-Za-z_][A-Za-z0-9_.-]*$", options: .regularExpression) != nil else {
            throw AuthorizationFailed(message: "用户名 \(user) 含有无法写入规则的字符")
        }
        let rule = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset sleepnow"
        // 先用 visudo 校验，通过后再放进 sudoers.d，避免写坏 sudo 配置。
        let shell = """
        f=$(/usr/bin/mktemp) && printf '%s\\n' '\(rule)' > "$f" && /usr/sbin/visudo -cf "$f" && \
        /usr/sbin/chown root:wheel "$f" && /bin/chmod 0440 "$f" && /bin/mv "$f" \(sudoersPath)
        """
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with prompt \"合盖运行需要修改系统睡眠设置的权限（只需授权一次）。\" with administrator privileges"
        var errorInfo: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
        guard let errorInfo else { return }
        if errorInfo[NSAppleScript.errorNumber] as? Int == -128 {
            throw AuthorizationCancelled()
        }
        throw AuthorizationFailed(message: errorInfo[NSAppleScript.errorMessage] as? String ?? "\(errorInfo)")
    }

    static func readDisabled() throws -> Bool {
        let output = try runCommand("/usr/bin/pmset", ["-g"])
        let line = output.split(separator: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("SleepDisabled") }
        return line?.split(whereSeparator: \.isWhitespace).last == "1"
    }

    static func setDisabled(_ disabled: Bool) throws {
        try runCommand("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", disabled ? "1" : "0"])
        log.info("disablesleep=\(disabled)")
    }

    static func sleepNow() throws {
        try runCommand("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "sleepnow"])
    }
}
