import Foundation
import CryptoKit
import Security

/// 令牌存本地加密文件，不再用钥匙串。
///
/// 为什么不用钥匙串：本 App 是 ad-hoc 签名（没有 Apple 证书），而 macOS 的钥匙串访问按
/// 「分区 ID」认人，非 Apple 签名程序的分区 ID 就是它的 cdhash（securityd 日志：
/// client is not Apple-signed / ACL partition mismatch / asking user about XARA partition）。
/// ad-hoc 签名每重新构建一次 cdhash 就变一次，于是每换一个构建都要重新授权一次；
/// 点「始终允许」只把当前这个 cdhash 加进白名单，下次构建又失效——表现就是反复弹密码框。
///
/// 加密：AES-GCM（CryptoKit，无第三方依赖）。密钥 = SHA256(固定前缀 + 本机硬件 UUID +
/// 当前用户名 + 每条记录独立随机 salt)，密钥本身不落盘，所以密文拷到别的机器或别的
/// 账户下都解不开。文件 0600、目录 0700，只有本用户可读。
enum TokenStore {
    private static let prefix = "glpm.token.v1|"
    private static let migratedKey = "tokenStoreMigratedAccounts"

    private struct Record: Codable {
        let salt: String   // hex
        let blob: String   // AES-GCM combined（nonce + 密文 + tag）的 base64
    }

    // MARK: - 位置

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(AppInfo.name, isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("tokens.json") }

    private static var machineKeyURL: URL { directory.appendingPathComponent(".machine-key") }

    // MARK: - 读写

    static func password(account: String) -> String? {
        migrateFromKeychain(account: account)
        guard let record = records()[account] else { return nil }
        return decrypt(record, account: account)
    }

    @discardableResult
    static func set(_ value: String, account: String) -> Bool {
        if value.isEmpty { return remove(account: account) }
        var all = records()
        guard let record = encrypt(value) else { return false }
        all[account] = record
        return write(all)
    }

    @discardableResult
    static func remove(account: String) -> Bool {
        var all = records()
        guard all[account] != nil else { return true }
        all[account] = nil
        return write(all)
    }

    /// 已存放令牌的账户（诊断用）
    static func accounts() -> [String] { records().keys.sorted() }

    /// 文件权限，诊断用（期望 0600）
    static func filePermissions() -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let mode = attrs[.posixPermissions] as? NSNumber else { return "无文件" }
        return String(format: "%04o", mode.intValue)
    }

    /// 某账户的令牌能否正常解密（诊断用，不暴露内容）
    static func decryptable(account: String) -> String {
        guard let record = records()[account] else { return "无记录" }
        return decrypt(record, account: account) != nil ? "可解密" : "解密失败"
    }

    // MARK: - 文件

    private static func records() -> [String: Record] {
        guard let data = try? Data(contentsOf: fileURL),
              let map = try? JSONDecoder().decode([String: Record].self, from: data) else { return [:] }
        return map
    }

    private static func write(_ map: [String: Record]) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            guard let data = try? JSONEncoder().encode(map) else { return false }
            try data.write(to: fileURL, options: [.atomic])
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return true
        } catch {
            NSLog("令牌写入失败: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - 加解密

    private static func encrypt(_ value: String) -> Record? {
        var saltBytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { saltBytes[i] = UInt8.random(in: 0...255) }
        let salt = Data(saltBytes)
        guard let sealed = try? AES.GCM.seal(Data(value.utf8), using: key(salt: salt, seed: machineSeed())),
              let combined = sealed.combined else { return nil }
        return Record(salt: salt.hexEncoded, blob: combined.base64EncodedString())
    }

    private static func decrypt(_ record: Record, account: String) -> String? {
        guard let salt = Data(hexEncoded: record.salt),
              let combined = Data(base64Encoded: record.blob),
              let box = try? AES.GCM.SealedBox(combined: combined) else { return nil }
        if let plain = try? AES.GCM.open(box, using: key(salt: salt, seed: machineSeed())) {
            return String(data: plain, encoding: .utf8)
        }
        // 机器指纹变过（早期版本没取到硬件 UUID，退回过随机机器密钥）：
        // 用旧种子解一次，成功就顺手按当前种子重新加密，用户不用重填令牌
        guard let legacy = legacySeed(),
              let plain = try? AES.GCM.open(box, using: key(salt: salt, seed: legacy)),
              let value = String(data: plain, encoding: .utf8) else {
            NSLog("令牌解密失败（换过机器或账户？），请在设置里重新填写令牌")
            return nil
        }
        set(value, account: account)
        return value
    }

    private static func key(salt: Data, seed: String) -> SymmetricKey {
        var hash = SHA256()
        hash.update(data: Data(prefix.utf8))
        hash.update(data: Data(seed.utf8))
        hash.update(data: Data(NSUserName().utf8))
        hash.update(data: salt)
        return SymmetricKey(data: hash.finalize())
    }

    // MARK: - 机器指纹

    private static var cachedSeed: String?

    /// 优先用硬件 UUID；拿不到就退回一个随机机器密钥（同样 0600，不落明文）
    private static func machineSeed() -> String {
        if let cached = cachedSeed { return cached }
        let seed: String
        if let uuid = hardwareUUID() {
            seed = "hw:" + uuid
        } else if let data = try? Data(contentsOf: machineKeyURL),
                  let existing = String(data: data, encoding: .utf8)?.trimmed,
                  !existing.isEmpty {
            seed = "rk:" + existing
        } else {
            var bytes = [UInt8](repeating: 0, count: 32)
            for i in 0..<32 { bytes[i] = UInt8.random(in: 0...255) }
            let fresh = Data(bytes).hexEncoded
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? fresh.write(to: machineKeyURL, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: machineKeyURL.path)
            seed = "rk:" + fresh
        }
        cachedSeed = seed
        return seed
    }

    private static func hardwareUUID() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        process.arguments = ["-rd1", "-c", "IOPlatformExpertDevice"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        // ioreg 的键是带引号的："IOPlatformUUID" = "6F40E77B-…"
        guard let found = text.range(of: #"IOPlatformUUID"\s*=\s*"([^"]+)"#, options: .regularExpression) else { return nil }
        let matched = String(text[found])
        guard let eq = matched.range(of: "= \"") else { return nil }
        var uuid = String(matched[eq.upperBound...]).trimmed
        if uuid.hasSuffix("\"") { uuid.removeLast() }
        uuid = uuid.trimmed
        return uuid.isEmpty ? nil : uuid
    }

    /// 当前用的是哪种机器指纹（诊断用）
    static func seedKind() -> String {
        machineSeed().hasPrefix("hw:") ? "硬件 UUID" : "随机机器密钥文件"
    }

    /// 旧版本退回过的随机机器密钥（只读，不创建），用于把老记录迁到硬件 UUID 种子
    private static func legacySeed() -> String? {
        guard let data = try? Data(contentsOf: machineKeyURL),
              let text = String(data: data, encoding: .utf8)?.trimmed,
              !text.isEmpty else { return nil }
        return "rk:" + text
    }

    // MARK: - 从钥匙串迁移（一次性，静默）

    private static func migrateFromKeychain(account: String) {
        var done = UserDefaults.standard.stringArray(forKey: migratedKey) ?? []
        guard !done.contains(account) else { return }
        done.append(account)
        UserDefaults.standard.set(done, forKey: migratedKey)
        guard records()[account] == nil, let old = legacyRead(account: account) else { return }
        set(old, account: account)
        legacyDelete(account: account)
    }

    /// 只静默读取：需要授权就直接放弃，不弹任何窗
    private static func legacyRead(account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: AppInfo.bundleID + ".token",
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne,
                                    kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func legacyDelete(account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: AppInfo.bundleID + ".token",
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }

    /// 钥匙串里残留的旧条目账户（诊断用）
    static func legacyAccounts() -> [String] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: AppInfo.bundleID + ".token",
                                    kSecMatchLimit as String: kSecMatchLimitAll,
                                    kSecReturnAttributes as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let items = out as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }
}

// MARK: - hex

extension Data {
    var hexEncoded: String { map { String(format: "%02x", $0) }.joined() }

    init?(hexEncoded: String) {
        guard hexEncoded.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hexEncoded.count / 2)
        var index = hexEncoded.startIndex
        while index < hexEncoded.endIndex {
            let next = hexEncoded.index(index, offsetBy: 2)
            guard let byte = UInt8(hexEncoded[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
