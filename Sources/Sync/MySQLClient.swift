//
//  MySQLClient.swift
//  SeafoodInventory
//
//  原生 MySQL 协议客户端（protocol 10，MySQL 5.7 / 8.0）。
//  只用 Network.framework + Security + CryptoKit，不引入任何第三方依赖。
//
//  ⚠️ 未编译验证：当前环境没有 Xcode / swiftc（容器里连 Swift 工具链都没有），
//  本文件只做了逐行人工检查 + 脚本化的括号/引号/字符串插值自查，没有编译过，
//  也没有连过真实 MySQL 服务器。集成后请先调用 SyncEngine.testConnection() 验证握手与认证链路。
//
//  协议覆盖点：
//  1. 握手包 protocol 10：server version / connection id / scramble / capabilities / auth plugin
//  2. 认证：mysql_native_password（SHA1 三段）、caching_sha2_password（SHA256；
//     fast auth 的 0x03 / 0x04 分支；需要 full auth 时：TLS 下发明文密码，
//     非 TLS 下用 SecKey + RSA-OAEP-SHA1 加密；公钥解析失败给出明确中文错误）
//  3. TLS：tls = disabled / preferred / required；preferred 失败会新建连接降级明文（绝不复用失败连接）
//  4. COM_QUERY + 结果集解析：列定义、数据行、OK 包 affectedRows、ERR 包错误码与消息；
//     NULL 返回 nil，其余值（整数 / 浮点 / 字符串 / 日期时间）一律按字符串取，不做本地类型转换
//  5. 超时：连接 8 秒、读取 15 秒；全部错误信息中文
//
//  已知限制（重要）：MySQL 原生 TLS 是「先明文握手，再在同一 TCP 连接内发 SSLRequest 升级」。
//  Network.framework 的 NWConnection 只能在建连时决定是否 TLS，无法中途升级。
//  所以本文件的 TLS 分支适用于「连上即 TLS」的部署（stunnel / HAProxy / 云厂商 TLS 终结代理）；
//  直连 MySQL 自带的 TLS 时，preferred 会自动降级明文，required 会直接报错并提示改用代理。
//  要支持 MySQL 原生 TLS 升级，必须换 CFStream（kCFStreamPropertySSLSettings 可在已建连接上升级）
//  或自建 TLS 握手，不在本文件范围内。
//

import Foundation
import Network
import Security
import CryptoKit

// MARK: - 错误

/// 客户端全部错误。errorDescription 一律中文，UI 可直接展示。
enum MySQLClientError: LocalizedError {
    case notConnected
    case dnsFailed(String)
    case refused(String)
    case connectTimeout(String)
    case readTimeout
    case writeTimeout
    case tlsFailed(String)
    case authFailed(String)
    case databaseNotExist(String)
    case server(code: Int, message: String)
    case protocolViolation(String)
    case unsupported(String)
    case ioError(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "MySQL 连接尚未建立"
        case .dnsFailed(let detail):
            return "域名解析失败：\(detail)"
        case .refused(let detail):
            return "拒绝连接：\(detail)"
        case .connectTimeout(let detail):
            return "连接超时（8 秒）：\(detail)"
        case .readTimeout:
            return "读取超时（15 秒）：服务端没有响应"
        case .writeTimeout:
            return "发送超时：网络写入阻塞"
        case .tlsFailed(let detail):
            return "TLS 连接失败：\(detail)"
        case .authFailed(let detail):
            return "认证失败：\(detail)"
        case .databaseNotExist(let detail):
            return "数据库不存在：\(detail)"
        case .server(let code, let message):
            return "MySQL 错误 \(code)：\(message)"
        case .protocolViolation(let detail):
            return "协议解析失败：\(detail)"
        case .unsupported(let detail):
            return "不支持的操作：\(detail)"
        case .ioError(let detail):
            return "网络读写失败：\(detail)"
        }
    }
}

// MARK: - 连接配置

/// 连接参数。dsn 形如 mysql://user:pass@host:3306/db，tls 取 disabled / preferred / required。
struct MySQLConfig: Equatable {
    var host: String
    var port: Int
    var user: String
    var password: String
    var database: String
    var tls: String

    init(host: String = "127.0.0.1",
         port: Int = 3306,
         user: String = "root",
         password: String = "",
         database: String = "seafood",
         tls: String = "preferred") {
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.database = database
        self.tls = tls
    }

    /// 解析失败返回 nil。preferred 不带进 dsn（省得每次写盘都有噪声），只有 disabled/required 才写 query。
    var dsn: String {
        var components = URLComponents()
        components.scheme = "mysql"
        components.host = host
        components.port = port
        components.user = user
        components.password = password.isEmpty ? nil : password
        let name = database.trimmingCharacters(in: .whitespacesAndNewlines)
        components.path = name.isEmpty ? "" : "/" + name
        if normalizedTLS != "preferred" {
            components.queryItems = [URLQueryItem(name: "tls", value: normalizedTLS)]
        }
        if let text = components.string, !text.isEmpty {
            return text
        }
        // 兜底：极端字符下 URLComponents 可能组不出字符串
        let auth = password.isEmpty ? user : user + ":" + password
        return "mysql://" + auth + "@" + host + ":" + String(port) + "/" + name
    }

    /// 归一化 TLS 模式，只返回 disabled / preferred / required 三种。
    var normalizedTLS: String {
        let value = tls.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch value {
        case "disabled", "disable", "off", "false", "none", "no":
            return "disabled"
        case "required", "require", "on", "true", "yes", "verify-ca", "verify-full":
            return "required"
        default:
            return "preferred"
        }
    }

    init?(dsn: String) {
        guard let parsed = MySQLConfig.parse(dsn) else { return nil }
        self = parsed
    }

    /// 兼容三种写法：
    ///   mysql://user:pass@host:3306/db
    ///   mysql://user:pass@host:3306/db?tls=required
    ///   host:3306/db（无 scheme，用户默认 root、密码空）
    static func parse(_ dsn: String) -> MySQLConfig? {
        let raw = dsn.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let text = raw.contains("://") ? raw : "mysql://" + raw
        guard let components = URLComponents(string: text) else { return nil }
        let scheme = (components.scheme ?? "").lowercased()
        guard scheme == "mysql" || scheme == "mariadb" else { return nil }
        guard let host = components.host, !host.isEmpty else { return nil }
        var database = components.path
        if database.hasPrefix("/") { database.removeFirst() }
        database = database.removingPercentEncoding ?? database
        guard !database.isEmpty else { return nil }
        var tls = "preferred"
        if let items = components.queryItems {
            for item in items {
                let name = item.name.lowercased()
                if name == "tls" || name == "sslmode" || name == "ssl-mode" {
                    tls = item.value ?? tls
                }
            }
        }
        let user = components.user?.removingPercentEncoding ?? "root"
        let password = components.password?.removingPercentEncoding ?? ""
        return MySQLConfig(host: host,
                           port: components.port ?? 3306,
                           user: user,
                           password: password,
                           database: database,
                           tls: tls)
    }
}

// MARK: - 客户端能力位

private enum ClientCapability {
    static let longPassword: UInt32 = 0x0000_0001
    static let longFlag: UInt32 = 0x0000_0004
    static let connectWithDB: UInt32 = 0x0000_0008
    static let protocol41: UInt32 = 0x0000_0200
    static let transactions: UInt32 = 0x0000_2000
    static let secureConnection: UInt32 = 0x0000_8000
    static let multiResults: UInt32 = 0x0002_0000
    static let pluginAuth: UInt32 = 0x0008_0000
    static let pluginAuthLenenc: UInt32 = 0x0020_0000
}

// MARK: - 认证哈希

private enum AuthCrypto {
    static func sha1(_ bytes: [UInt8]) -> [UInt8] {
        Array(Insecure.SHA1.hash(data: Data(bytes)))
    }

    static func sha256(_ bytes: [UInt8]) -> [UInt8] {
        Array(SHA256.hash(data: Data(bytes)))
    }

    static func xor(_ lhs: [UInt8], _ rhs: [UInt8]) -> [UInt8] {
        let count = min(lhs.count, rhs.count)
        var out = [UInt8](repeating: 0, count: count)
        var index = 0
        while index < count {
            out[index] = lhs[index] ^ rhs[index]
            index += 1
        }
        return out
    }

    /// mysql_native_password：SHA1(password) XOR SHA1(scramble + SHA1(SHA1(password)))
    static func nativePassword(_ password: String, scramble: [UInt8]) -> [UInt8] {
        guard !password.isEmpty else { return [] }
        let stage1 = sha1(Array(password.utf8))
        let stage2 = sha1(stage1)
        let stage3 = sha1(scramble + stage2)
        return xor(stage1, stage3)
    }

    /// caching_sha2_password：SHA256(password) XOR SHA256(SHA256(SHA256(password)) + scramble)
    static func cachingSHA2Password(_ password: String, scramble: [UInt8]) -> [UInt8] {
        guard !password.isEmpty else { return [] }
        let stage1 = sha256(Array(password.utf8))
        let stage2 = sha256(stage1)
        let stage3 = sha256(stage2 + scramble)
        return xor(stage1, stage3)
    }
}

// MARK: - RSA-OAEP 加密（caching_sha2_password 的 full auth 路径）

private enum RSAAuth {
    /// 用服务端下发的 PEM 公钥做 RSA-OAEP(SHA1) 加密。
    /// MySQL 8 下发的是 "-----BEGIN PUBLIC KEY-----"（SubjectPublicKeyInfo），
    /// 而 SecKeyCreateWithData 只认 PKCS#1 RSAPublicKey，所以要先剥掉 SPKI 外壳。
    static func encryptOAEP(pem: String, plain: [UInt8]) throws -> [UInt8] {
        let der = try decodePEM(pem)
        let pkcs1 = try extractPKCS1(from: der)
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic
        ]
        var keyError: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(Data(pkcs1) as CFData,
                                            attributes as CFDictionary,
                                            &keyError) else {
            throw MySQLClientError.authFailed("服务端 RSA 公钥无法解析（" + describe(keyError) + "）")
        }
        guard SecKeyIsAlgorithmSupported(key, .encrypt, .rsaEncryptionOAEPSHA1) else {
            throw MySQLClientError.authFailed("服务端 RSA 公钥不支持 OAEP-SHA1 加密")
        }
        var encryptError: Unmanaged<CFError>?
        guard let encrypted = SecKeyCreateEncryptedData(key,
                                                       .rsaEncryptionOAEPSHA1,
                                                       Data(plain) as CFData,
                                                       &encryptError) else {
            throw MySQLClientError.authFailed("RSA-OAEP 加密失败（" + describe(encryptError) + "）")
        }
        return [UInt8](encrypted as Data)
    }

    private static func describe(_ error: Unmanaged<CFError>?) -> String {
        guard let error else { return "未知错误" }
        let value = error.takeRetainedValue()
        return (value as Error).localizedDescription
    }

    private static func decodePEM(_ pem: String) throws -> [UInt8] {
        let body = pem
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("-----") }
            .joined()
        guard !body.isEmpty,
              let data = Data(base64Encoded: body, options: [.ignoreUnknownCharacters]) else {
            throw MySQLClientError.authFailed("服务端公钥 PEM 解码失败（base64 非法）")
        }
        return [UInt8](data)
    }

    /// 返回 PKCS#1 形式的 RSAPublicKey DER。
    private static func extractPKCS1(from der: [UInt8]) throws -> [UInt8] {
        var index = 0
        let outer = try readTLV(der, &index)
        guard outer.tag == 0x30 else {
            throw MySQLClientError.authFailed("服务端公钥不是 ASN.1 SEQUENCE")
        }
        var cursor = outer.start
        let first = try readTLV(der, &cursor)
        if first.tag == 0x02 {
            // 已经是 PKCS#1：SEQUENCE { INTEGER modulus, INTEGER exponent }
            return Array(der[0..<outer.end])
        }
        guard first.tag == 0x30 else {
            throw MySQLClientError.authFailed("服务端公钥缺少 AlgorithmIdentifier")
        }
        let bitString = try readTLV(der, &cursor)
        guard bitString.tag == 0x03 else {
            throw MySQLClientError.authFailed("服务端公钥缺少 BIT STRING")
        }
        var inner = bitString.start
        guard inner < bitString.end, der[inner] == 0x00 else {
            throw MySQLClientError.authFailed("服务端公钥 BIT STRING 头部非法")
        }
        inner += 1
        let headerStart = inner
        var innerCursor = inner
        let key = try readTLV(der, &innerCursor)
        guard key.tag == 0x30 else {
            throw MySQLClientError.authFailed("服务端公钥内层不是 SEQUENCE")
        }
        return Array(der[headerStart..<key.end])
    }

    private struct TLV {
        var tag: UInt8
        var start: Int
        var end: Int
    }

    private static func readTLV(_ bytes: [UInt8], _ index: inout Int) throws -> TLV {
        guard index + 2 <= bytes.count else {
            throw MySQLClientError.authFailed("ASN.1 数据不完整")
        }
        let tag = bytes[index]
        index += 1
        var length = Int(bytes[index])
        index += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count >= 1, count <= 4, index + count <= bytes.count else {
                throw MySQLClientError.authFailed("ASN.1 长度字段非法")
            }
            length = 0
            var used = 0
            while used < count {
                length = (length << 8) | Int(bytes[index])
                index += 1
                used += 1
            }
        }
        guard length >= 0, index + length <= bytes.count else {
            throw MySQLClientError.authFailed("ASN.1 长度越界")
        }
        let start = index
        index += length
        return TLV(tag: tag, start: start, end: start + length)
    }
}

// MARK: - 服务端握手信息

private struct ServerHandshake {
    var serverVersion: String
    var connectionID: UInt32
    var scramble: [UInt8]
    var capabilities: UInt32
    var authPlugin: String
}

// MARK: - 客户端

/// 原生 MySQL 客户端。线程约束：同一个实例只允许在同一个串行队列上调用
/// （SyncEngine 用一条后台串行队列驱动它），内部不做加锁。
final class MySQLClient {
    private static let connectTimeout: TimeInterval = 8
    private static let readTimeout: TimeInterval = 15
    private static let writeTimeout: TimeInterval = 15

    /// preferred 模式下「TLS 直连是否可用」的探测结果缓存，key 是 host:port。
    /// 不缓存的话，每次连普通 MySQL 都要先失败一次 TLS 握手，白等 8 秒。
    private static let tlsCachePrefix = "mysql.tls.probe."

    private let config: MySQLConfig
    private let netQueue = DispatchQueue(label: "com.yoyulyvw.seafood.mysql.net")

    private var connection: NWConnection?

    private let inboxLock = NSLock()
    private var inbox = Data()
    private var pendingError: Error?
    private var receiveClosed = false
    private let receiveSignal = DispatchSemaphore(value: 0)

    private var sequence: UInt8 = 0
    private var isOpen = false
    /// 连接代数：close() 时自增，用来丢弃旧连接迟到的 receive 回调（否则超时重连后会串数据）
    private var generation: Int = 0

    private var scramble: [UInt8] = []
    private var authPluginName = "mysql_native_password"
    private var usingTLS = false

    private(set) var serverVersion: String = ""

    init(config: MySQLConfig) {
        self.config = config
    }

    deinit {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
    }

    // MARK: 生命周期

    /// 握手 + 认证。重复调用会先关掉旧连接。
    func connect() throws {
        close()
        switch config.normalizedTLS {
        case "disabled":
            try establish(useTLS: false)
        case "required":
            do {
                try establish(useTLS: true)
            } catch {
                close()
                throw requiredTLSError(error)
            }
        default:
            try connectPreferred()
        }
    }

    func close() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        isOpen = false
        sequence = 0
        generation &+= 1
        inboxLock.lock()
        inbox.removeAll(keepingCapacity: false)
        pendingError = nil
        receiveClosed = false
        inboxLock.unlock()
        while receiveSignal.wait(timeout: .now()) == .success {
            // 清空残留信号，避免下一轮读被"假唤醒"
        }
    }

    /// 清掉 TLS 探测缓存（改了配置、换了网络环境后可以调一次）。
    static func resetTLSProbeCache() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(tlsCachePrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    private var cacheKey: String {
        "\(config.host):\(config.port)"
    }

    private static func cachedTLS(for key: String) -> Bool? {
        let full = tlsCachePrefix + key
        guard UserDefaults.standard.object(forKey: full) != nil else { return nil }
        return UserDefaults.standard.bool(forKey: full)
    }

    private static func storeTLS(_ value: Bool, for key: String) {
        UserDefaults.standard.set(value, forKey: tlsCachePrefix + key)
    }

    /// preferred：先试 TLS，失败换新连接走明文；成功/失败结果缓存，避免每次重扫。
    private func connectPreferred() throws {
        var order: [Bool]
        if let cached = MySQLClient.cachedTLS(for: cacheKey) {
            order = cached ? [true, false] : [false, true]
        } else {
            order = [true, false]
        }
        var lastError: Error = MySQLClientError.notConnected
        var index = 0
        while index < order.count {
            let useTLS = order[index]
            do {
                try establish(useTLS: useTLS)
                MySQLClient.storeTLS(useTLS, for: cacheKey)
                return
            } catch let error as MySQLClientError {
                lastError = error
                close()
                // 认证失败 / 库不存在跟传输层无关，换明文再试一次也是白试
                switch error {
                case .authFailed, .databaseNotExist:
                    throw error
                default:
                    break
                }
            } catch {
                lastError = error
                close()
            }
            index += 1
        }
        throw lastError
    }

    private func establish(useTLS: Bool) throws {
        self.usingTLS = useTLS
        self.sequence = 0
        let conn = try openConnection(useTLS: useTLS)
        connection = conn
        do {
            let handshake = try readInitialHandshake()
            serverVersion = handshake.serverVersion
            scramble = handshake.scramble
            authPluginName = handshake.authPlugin.isEmpty ? "mysql_native_password" : handshake.authPlugin
            try sendHandshakeResponse(handshake)
            try awaitAuthResult()
            isOpen = true
        } catch {
            // 任何一步失败都要把 socket 收掉，避免半开连接堆在后台
            close()
            throw error
        }
    }

    // MARK: 建链

    private func openConnection(useTLS: Bool) throws -> NWConnection {
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: config.port)) else {
            throw MySQLClientError.unsupported("端口非法：" + String(config.port))
        }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Int(MySQLClient.connectTimeout)
        tcp.noDelay = true
        let parameters: NWParameters
        if useTLS {
            let tls = NWProtocolTLS.Options()
            let security = tls.securityProtocolOptions
            // MySQL 服务端默认是自签证书，这里不做证书链校验，只保证链路加密
            sec_protocol_options_set_verify_block(security, { _, _, complete in
                complete(true)
            }, netQueue)
            if IPv4Address(config.host) == nil && IPv6Address(config.host) == nil {
                sec_protocol_options_set_tls_server_name(security, config.host)
            }
            parameters = NWParameters(tls: tls, tcp: tcp)
        } else {
            parameters = NWParameters(tcp: tcp)
        }
        parameters.allowLocalEndpointReuse = true
        let conn = NWConnection(host: NWEndpoint.Host(config.host), port: port, using: parameters)
        try startAndWaitReady(conn)
        return conn
    }

    private func startAndWaitReady(_ conn: NWConnection) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var failure: NWError?
        var ready = false
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready = true
                semaphore.signal()
            case .failed(let error):
                failure = error
                semaphore.signal()
            case .waiting(let error):
                // DNS 失败 / 拒绝连接会先落 waiting；这类错误不会自愈，直接按失败处理
                if MySQLClient.isFatalWaiting(error) {
                    failure = error
                    semaphore.signal()
                }
            case .cancelled:
                if !ready && failure == nil {
                    failure = .posix(.ECANCELED)
                    semaphore.signal()
                }
            default:
                break
            }
        }
        conn.start(queue: netQueue)
        if semaphore.wait(timeout: .now() + MySQLClient.connectTimeout) == .timedOut {
            conn.cancel()
            throw MySQLClientError.connectTimeout(config.host + ":" + String(config.port))
        }
        if !ready, let failure {
            conn.cancel()
            throw classify(failure)
        }
        if !ready {
            conn.cancel()
            throw MySQLClientError.connectTimeout(config.host + ":" + String(config.port))
        }
    }

    private static func isFatalWaiting(_ error: NWError) -> Bool {
        if case .dns = error { return true }
        if case .tls = error { return true }
        if case .posix(let code) = error {
            switch code {
            case .ECONNREFUSED, .EHOSTUNREACH, .ENETUNREACH, .ETIMEDOUT, .EACCES:
                return true
            default:
                return false
            }
        }
        return false
    }

    private func classify(_ error: NWError) -> MySQLClientError {
        switch error {
        case .dns(let code):
            return .dnsFailed("无法解析主机 " + config.host + "（DNSService 错误码 " + String(code) + "）")
        case .posix(let code):
            switch code {
            case .ECONNREFUSED:
                return .refused(config.host + ":" + String(config.port) + " 端口未监听或被防火墙拦截")
            case .ETIMEDOUT:
                return .connectTimeout(config.host + ":" + String(config.port))
            case .EHOSTUNREACH, .ENETUNREACH:
                return .refused("网络不可达，无法连接 " + config.host + ":" + String(config.port))
            case .ECONNRESET:
                return .ioError("连接被重置（" + config.host + ":" + String(config.port) + "）")
            default:
                return .ioError("连接失败（POSIX " + String(code.rawValue) + "）：" + error.localizedDescription)
            }
        case .tls(let status):
            return .tlsFailed("TLS 握手失败（OSStatus " + String(status) + "）")
        default:
            return .ioError("连接失败：" + error.localizedDescription)
        }
    }

    private func requiredTLSError(_ error: Error) -> MySQLClientError {
        if let clientError = error as? MySQLClientError {
            switch clientError {
            case .authFailed, .databaseNotExist, .dnsFailed, .refused:
                return clientError
            default:
                break
            }
        }
        let detail = error.localizedDescription
        return .tlsFailed(detail + "。注意：MySQL 原生 TLS 需要在同一 TCP 连接内二次升级，"
            + "Network.framework 不支持中途升级；请把 tls 设为 preferred/disabled，"
            + "或在服务端前置 stunnel / HAProxy 之类的 TLS 终结代理")
    }

    // MARK: 包读写

    private func readExact(_ count: Int) throws -> [UInt8] {
        if count <= 0 { return [] }
        try fillInbox(count)
        inboxLock.lock()
        let out = Array(inbox.prefix(count))
        inbox.removeFirst(count)
        inboxLock.unlock()
        return out
    }

    private func fillInbox(_ need: Int) throws {
        var rounds = 0
        while true {
            inboxLock.lock()
            let have = inbox.count
            let error = pendingError
            let closed = receiveClosed
            inboxLock.unlock()
            if have >= need { return }
            if let error {
                throw MySQLClientError.ioError(error.localizedDescription)
            }
            if closed {
                throw MySQLClientError.ioError("服务端已关闭连接")
            }
            rounds += 1
            if rounds > 4096 {
                throw MySQLClientError.protocolViolation("读取循环异常（数据未到齐）")
            }
            try receiveOnce()
        }
    }

    private func receiveOnce() throws {
        guard let conn = connection else { throw MySQLClientError.notConnected }
        while receiveSignal.wait(timeout: .now()) == .success {
            // 清残留
        }
        let expected = generation
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            self.inboxLock.lock()
            // 旧连接（已经 close 过）迟到的回调直接丢弃，不能污染新一轮连接的缓冲区
            if expected == self.generation {
                if let data, !data.isEmpty {
                    self.inbox.append(data)
                }
                if let error {
                    self.pendingError = error
                }
                if isComplete {
                    self.receiveClosed = true
                }
            }
            self.inboxLock.unlock()
            self.receiveSignal.signal()
        }
        if receiveSignal.wait(timeout: .now() + MySQLClient.readTimeout) == .timedOut {
            close()
            throw MySQLClientError.readTimeout
        }
    }

    private func sendBytes(_ bytes: [UInt8]) throws {
        guard let conn = connection else { throw MySQLClientError.notConnected }
        let semaphore = DispatchSemaphore(value: 0)
        var failure: Error?
        conn.send(content: Data(bytes), completion: .contentProcessed { error in
            if let error { failure = error }
            semaphore.signal()
        })
        if semaphore.wait(timeout: .now() + MySQLClient.writeTimeout) == .timedOut {
            throw MySQLClientError.writeTimeout
        }
        if let failure {
            throw MySQLClientError.ioError(failure.localizedDescription)
        }
    }

    private func writePacket(_ payload: [UInt8]) throws {
        let maxChunk = 0x00FF_FFFF
        if payload.isEmpty {
            try writeFrame(payload, offset: 0, length: 0)
            return
        }
        var offset = 0
        var remaining = payload.count
        while remaining > 0 {
            let chunk = min(maxChunk, remaining)
            try writeFrame(payload, offset: offset, length: chunk)
            offset += chunk
            remaining -= chunk
            if remaining == 0 && chunk == maxChunk {
                // 恰好整 16MB 时需要补一个空尾包，服务端才知道结束
                try writeFrame(payload, offset: offset, length: 0)
            }
        }
    }

    private func writeFrame(_ payload: [UInt8], offset: Int, length: Int) throws {
        var frame = [UInt8]()
        frame.reserveCapacity(length + 4)
        frame.append(UInt8(length & 0xFF))
        frame.append(UInt8((length >> 8) & 0xFF))
        frame.append(UInt8((length >> 16) & 0xFF))
        frame.append(sequence)
        sequence = sequence &+ 1
        if length > 0 {
            frame.append(contentsOf: payload[offset..<(offset + length)])
        }
        try sendBytes(frame)
    }

    private func readPacket() throws -> [UInt8] {
        var payload: [UInt8] = []
        var rounds = 0
        while true {
            rounds += 1
            if rounds > 256 {
                throw MySQLClientError.protocolViolation("结果包过大（分片超过 256 段）")
            }
            let header = try readExact(4)
            let length = Int(header[0]) | (Int(header[1]) << 8) | (Int(header[2]) << 16)
            sequence = header[3] &+ 1
            if length > 0 {
                payload.append(contentsOf: try readExact(length))
            }
            if length < 0x00FF_FFFF { break }
        }
        return payload
    }

    // MARK: 握手

    private func readInitialHandshake() throws -> ServerHandshake {
        let packet = try readPacket()
        guard let status = packet.first else {
            throw MySQLClientError.protocolViolation("握手包为空")
        }
        if status == 0xFF {
            throw serverErrorPacket(packet)
        }
        guard status == 10 else {
            throw MySQLClientError.unsupported("服务端协议版本 "
                + String(status) + "，仅支持 protocol 10（MySQL 5.7 / 8.0）")
        }
        var index = 1
        guard let version = readNulString(packet, &index) else {
            throw MySQLClientError.protocolViolation("握手包缺少 server version")
        }
        guard index + 4 <= packet.count else {
            throw MySQLClientError.protocolViolation("握手包缺少 connection id")
        }
        let connectionID = readUInt32(packet, index)
        index += 4
        guard index + 8 <= packet.count else {
            throw MySQLClientError.protocolViolation("握手包缺少 scramble 前 8 字节")
        }
        var scrambleBytes = Array(packet[index..<(index + 8)])
        index += 8
        if index < packet.count { index += 1 }        // filler 0x00
        var capabilities: UInt32 = 0
        if index + 2 <= packet.count {
            capabilities = UInt32(readUInt16(packet, index))
            index += 2
        }
        var authLength = 0
        if index < packet.count {
            index += 1                                 // charset
            if index + 2 <= packet.count { index += 2 } // status flags
            if index + 2 <= packet.count {
                capabilities |= UInt32(readUInt16(packet, index)) << 16
                index += 2
            }
            if index < packet.count {
                authLength = Int(packet[index])
                index += 1
            }
            index = min(index + 10, packet.count)       // reserved 10 字节
        }
        if index < packet.count {
            let want = max(13, authLength - 8)
            let take = min(packet.count - index, want)
            var tail = Array(packet[index..<(index + take)])
            index += take
            while let last = tail.last, last == 0 {
                tail.removeLast()
            }
            scrambleBytes.append(contentsOf: tail)
        }
        while let last = scrambleBytes.last, last == 0 {
            scrambleBytes.removeLast()
        }
        if scrambleBytes.count > 20 {
            scrambleBytes = Array(scrambleBytes.prefix(20))
        }
        var plugin = ""
        if index < packet.count {
            plugin = readNulString(packet, &index) ?? ""
        }
        if plugin.isEmpty { plugin = "mysql_native_password" }
        return ServerHandshake(serverVersion: version,
                               connectionID: connectionID,
                               scramble: scrambleBytes,
                               capabilities: capabilities,
                               authPlugin: plugin)
    }

    private func sendHandshakeResponse(_ handshake: ServerHandshake) throws {
        let desired: UInt32 =
            ClientCapability.longPassword |
            ClientCapability.longFlag |
            ClientCapability.protocol41 |
            ClientCapability.transactions |
            ClientCapability.secureConnection |
            ClientCapability.pluginAuth |
            ClientCapability.pluginAuthLenenc |
            ClientCapability.multiResults |
            ClientCapability.connectWithDB
        let capabilities = desired & handshake.capabilities
        guard capabilities & ClientCapability.protocol41 != 0 else {
            throw MySQLClientError.unsupported("服务端不支持 CLIENT_PROTOCOL_41（MySQL 版本过旧）")
        }
        let auth = authResponse(plugin: authPluginName,
                                password: config.password,
                                scramble: scramble)
        var payload = [UInt8]()
        payload.reserveCapacity(64 + auth.count + config.database.utf8.count)
        appendUInt32(&payload, capabilities)
        appendUInt32(&payload, 0x0100_0000)            // max packet size 16MB
        payload.append(45)                              // utf8mb4_general_ci
        payload.append(contentsOf: [UInt8](repeating: 0, count: 23))
        payload.append(contentsOf: Array(config.user.utf8))
        payload.append(0)
        // CLIENT_PLUGIN_AUTH_LENENC_CLIENT_DATA：长度编码；认证响应不会超过 250 字节，1 字节即可
        payload.append(UInt8(auth.count & 0xFF))
        payload.append(contentsOf: auth)
        if capabilities & ClientCapability.connectWithDB != 0 {
            payload.append(contentsOf: Array(config.database.utf8))
            payload.append(0)
        }
        if capabilities & ClientCapability.pluginAuth != 0 {
            payload.append(contentsOf: Array(authPluginName.utf8))
            payload.append(0)
        }
        // 注意：这里不设置 CLIENT_SSL。本文件的 TLS 是连接级 TLS（NWParameters.tls），
        // 不是 MySQL 的 SSLRequest 升级，所以不能向服务端声明 CLIENT_SSL。
        try writePacket(payload)
    }

    private func authResponse(plugin: String, password: String, scramble: [UInt8]) -> [UInt8] {
        if password.isEmpty { return [] }
        switch plugin {
        case "mysql_native_password":
            return AuthCrypto.nativePassword(password, scramble: scramble)
        case "caching_sha2_password":
            return AuthCrypto.cachingSHA2Password(password, scramble: scramble)
        case "mysql_clear_password":
            // 明文插件只在 TLS 下可用
            var out = Array(password.utf8)
            out.append(0)
            return out
        case "sha256_password":
            if usingTLS {
                var out = Array(password.utf8)
                out.append(0)
                return out
            }
            return [0x01]                          // 请求服务端下发 RSA 公钥
        default:
            // 未知插件先按 native 响应，服务端需要时会发 AuthSwitchRequest 纠正
            return AuthCrypto.nativePassword(password, scramble: scramble)
        }
    }

    private func awaitAuthResult() throws {
        var rounds = 0
        while true {
            rounds += 1
            if rounds > 8 {
                throw MySQLClientError.protocolViolation("认证流程异常：来回包过多")
            }
            let packet = try readPacket()
            guard let status = packet.first else {
                throw MySQLClientError.protocolViolation("认证阶段收到空包")
            }
            switch status {
            case 0x00:
                return                                  // OK
            case 0xFF:
                throw serverErrorPacket(packet)
            case 0xFE:
                try handleAuthSwitch(packet)
            case 0x01:
                try handleAuthMoreData(packet)
            default:
                throw MySQLClientError.protocolViolation(String(format: "认证阶段收到未知包头 0x%02X", status))
            }
        }
    }

    private func handleAuthSwitch(_ packet: [UInt8]) throws {
        var index = 1
        guard let plugin = readNulString(packet, &index), !plugin.isEmpty else {
            throw MySQLClientError.protocolViolation("认证切换包缺少插件名")
        }
        var data: [UInt8] = []
        if index < packet.count {
            data = Array(packet[index...])
        }
        while let last = data.last, last == 0 {
            data.removeLast()
        }
        authPluginName = plugin
        scramble = data
        let response = authResponse(plugin: plugin, password: config.password, scramble: data)
        try writePacket(response)
    }

    private func handleAuthMoreData(_ packet: [UInt8]) throws {
        let data = Array(packet.dropFirst())
        guard let code = data.first else {
            throw MySQLClientError.protocolViolation("AuthMoreData 包为空")
        }
        switch authPluginName {
        case "caching_sha2_password":
            switch code {
            case 0x03:
                // fast auth 成功，紧接着服务端会发 OK 包
                return
            case 0x04:
                if usingTLS {
                    try sendCleartextPassword()
                } else {
                    try requestPublicKey(prefix: 0x02)
                }
            default:
                if code == UInt8(ascii: "-") {
                    // 服务端主动下发了 PEM 公钥
                    let pem = String(decoding: data, as: UTF8.self)
                    try sendEncryptedPassword(pem: pem, prefix: 0x02)
                } else {
                    throw MySQLClientError.protocolViolation(
                        String(format: "caching_sha2_password 未知状态码 0x%02X", code))
                }
            }
        case "sha256_password":
            if code == UInt8(ascii: "-") {
                let pem = String(decoding: data, as: UTF8.self)
                // sha256_password 的公钥请求包是 0x01，加密密码包不带前缀
                try sendEncryptedPassword(pem: pem, prefix: nil)
            } else if usingTLS {
                try sendCleartextPassword()
            } else {
                throw MySQLClientError.unsupported("sha256_password 未收到服务端公钥")
            }
        case "mysql_clear_password":
            try sendCleartextPassword()
        default:
            throw MySQLClientError.unsupported("认证插件 " + authPluginName + " 需要额外数据，暂不支持")
        }
    }

    private func requestPublicKey(prefix: UInt8) throws {
        try writePacket([prefix])
        let packet = try readPacket()
        guard let status = packet.first else {
            throw MySQLClientError.protocolViolation("公钥包为空")
        }
        if status == 0xFF {
            throw serverErrorPacket(packet)
        }
        guard status == 0x01 else {
            throw MySQLClientError.protocolViolation(
                String(format: "期望公钥包（0x01），实际收到 0x%02X", status))
        }
        let pem = String(decoding: packet.dropFirst(), as: UTF8.self)
        try sendEncryptedPassword(pem: pem, prefix: prefix)
    }

    /// full auth 的明文密码回包。
    /// 说明：服务端 AuthMoreData 的状态字节（0x04）在读取时已经被消费掉，
    /// 客户端回包只放 password + NUL，不能带 0x01/0x02 前缀，否则前缀会被当成密码首字符。
    private func sendCleartextPassword() throws {
        var payload = Array(config.password.utf8)
        payload.append(0)
        try writePacket(payload)
    }

    private func sendEncryptedPassword(pem: String, prefix: UInt8?) throws {
        var plain = Array(config.password.utf8)
        plain.append(0)
        let encrypted = try RSAAuth.encryptOAEP(pem: pem, plain: plain)
        var payload = [UInt8]()
        if let prefix { payload.append(prefix) }
        payload.append(contentsOf: encrypted)
        try writePacket(payload)
    }

    // MARK: 查询

    /// 执行 SQL，返回 affectedRows。若语句返回结果集，则把结果集读完并返回 0。
    func execute(_ sql: String) throws -> Int {
        guard isOpen else { throw MySQLClientError.notConnected }
        try writePacket(comQuery(sql))
        let packet = try readPacket()
        guard let status = packet.first else {
            throw MySQLClientError.protocolViolation("执行返回空包")
        }
        if status == 0xFF { throw serverErrorPacket(packet) }
        if status == 0x00 {
            var index = 1
            let affected = readLenencUInt(packet, &index) ?? 0
            return Int(affected)
        }
        if status == 0xFB {
            throw MySQLClientError.unsupported("不支持 LOCAL INFILE 请求")
        }
        // 有结果集：读完丢掉
        var index = 0
        let columnCount = Int(readLenencUInt(packet, &index) ?? 0)
        var left = columnCount
        while left > 0 {
            _ = try readPacket()
            left -= 1
        }
        let eof = try readPacket()
        if isEOFPacket(eof) {
            while true {
                let row = try readPacket()
                if isEOFPacket(row) { break }
                if row.first == 0xFF { throw serverErrorPacket(row) }
            }
        }
        return 0
    }

    /// 执行查询，返回结果集。所有值按字符串返回，NULL 为 nil。
    func query(_ sql: String) throws -> [[String: String?]] {
        guard isOpen else { throw MySQLClientError.notConnected }
        try writePacket(comQuery(sql))
        let first = try readPacket()
        guard let status = first.first else {
            throw MySQLClientError.protocolViolation("查询返回空包")
        }
        if status == 0xFF { throw serverErrorPacket(first) }
        if status == 0x00 { return [] }                 // 没有结果集的 OK 包
        if status == 0xFB {
            throw MySQLClientError.unsupported("不支持 LOCAL INFILE 请求")
        }
        var index = 0
        guard let rawCount = readLenencUInt(first, &index) else {
            throw MySQLClientError.protocolViolation("无法解析列数量")
        }
        let columnCount = Int(rawCount)
        var names: [String] = []
        names.reserveCapacity(columnCount)
        var left = columnCount
        while left > 0 {
            let definition = try readPacket()
            names.append(try columnName(definition))
            left -= 1
        }
        let eof = try readPacket()
        guard isEOFPacket(eof) else {
            throw MySQLClientError.protocolViolation("列定义后缺少 EOF 包")
        }
        var rows: [[String: String?]] = []
        while true {
            let packet = try readPacket()
            if isEOFPacket(packet) { break }
            if packet.first == 0xFF { throw serverErrorPacket(packet) }
            rows.append(parseRow(packet, names: names))
        }
        return rows
    }

    private func comQuery(_ sql: String) -> [UInt8] {
        var payload: [UInt8] = [0x03]                   // COM_QUERY
        payload.append(contentsOf: Array(sql.utf8))
        return payload
    }

    private func columnName(_ definition: [UInt8]) throws -> String {
        var index = 0
        var skip = 4                                    // catalog / schema / table / org_table
        while skip > 0 {
            guard readLenencString(definition, &index) != nil else {
                throw MySQLClientError.protocolViolation("列定义字段不足")
            }
            skip -= 1
        }
        guard let name = readLenencString(definition, &index) else {
            throw MySQLClientError.protocolViolation("列定义缺少列名")
        }
        return name
    }

    private func parseRow(_ packet: [UInt8], names: [String]) -> [String: String?] {
        var row: [String: String?] = [:]
        row.reserveCapacity(names.count)
        var index = 0
        for name in names {
            var cell: String? = nil
            if index < packet.count {
                if packet[index] == 0xFB {
                    index += 1                          // NULL
                } else {
                    cell = readLenencString(packet, &index)
                    if cell == nil { index += 1 }        // 兜底，避免死循环
                }
            }
            row.updateValue(cell, forKey: name)
        }
        return row
    }

    // MARK: 字节工具

    private func appendUInt32(_ buffer: inout [UInt8], _ value: UInt32) {
        buffer.append(UInt8(value & 0xFF))
        buffer.append(UInt8((value >> 8) & 0xFF))
        buffer.append(UInt8((value >> 16) & 0xFF))
        buffer.append(UInt8((value >> 24) & 0xFF))
    }

    private func readUInt16(_ bytes: [UInt8], _ index: Int) -> UInt16 {
        guard index + 1 < bytes.count else { return 0 }
        return UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
    }

    private func readUInt32(_ bytes: [UInt8], _ index: Int) -> UInt32 {
        guard index + 3 < bytes.count else { return 0 }
        return UInt32(bytes[index])
            | (UInt32(bytes[index + 1]) << 8)
            | (UInt32(bytes[index + 2]) << 16)
            | (UInt32(bytes[index + 3]) << 24)
    }

    private func readNulString(_ bytes: [UInt8], _ index: inout Int) -> String? {
        guard index < bytes.count else { return nil }
        var end = index
        while end < bytes.count && bytes[end] != 0 {
            end += 1
        }
        let text = String(decoding: bytes[index..<end], as: UTF8.self)
        index = min(end + 1, bytes.count)
        return text
    }

    private func readLenencUInt(_ bytes: [UInt8], _ index: inout Int) -> UInt64? {
        guard index < bytes.count else { return nil }
        let first = bytes[index]
        index += 1
        switch first {
        case 0xFB:
            return nil
        case 0xFC:
            guard index + 2 <= bytes.count else { return nil }
            let value = UInt64(bytes[index]) | (UInt64(bytes[index + 1]) << 8)
            index += 2
            return value
        case 0xFD:
            guard index + 3 <= bytes.count else { return nil }
            let value = UInt64(bytes[index])
                | (UInt64(bytes[index + 1]) << 8)
                | (UInt64(bytes[index + 2]) << 16)
            index += 3
            return value
        case 0xFE:
            guard index + 8 <= bytes.count else { return nil }
            var value: UInt64 = 0
            var shift = 0
            while shift < 64 {
                value |= UInt64(bytes[index]) << UInt64(shift)
                index += 1
                shift += 8
            }
            return value
        case 0xFF:
            return nil
        default:
            return UInt64(first)
        }
    }

    private func readLenencString(_ bytes: [UInt8], _ index: inout Int) -> String? {
        guard index < bytes.count else { return nil }
        if bytes[index] == 0xFB {
            index += 1
            return nil
        }
        guard let length = readLenencUInt(bytes, &index) else { return nil }
        let count = Int(length)
        guard count >= 0, index + count <= bytes.count else {
            index = bytes.count
            return nil
        }
        let text = String(decoding: bytes[index..<(index + count)], as: UTF8.self)
        index += count
        return text
    }

    private func isEOFPacket(_ packet: [UInt8]) -> Bool {
        guard let status = packet.first else { return false }
        return status == 0xFE && packet.count < 9
    }

    private func serverErrorPacket(_ packet: [UInt8]) -> MySQLClientError {
        guard packet.count >= 3 else {
            return .protocolViolation("错误包格式异常")
        }
        let code = Int(packet[1]) | (Int(packet[2]) << 8)
        var index = 3
        var state = ""
        if index < packet.count, packet[index] == UInt8(ascii: "#") {
            index += 1
            if index + 5 <= packet.count {
                state = String(decoding: packet[index..<(index + 5)], as: UTF8.self)
                index += 5
            }
        }
        var message = ""
        if index < packet.count {
            message = String(decoding: packet[index...], as: UTF8.self)
        }
        if !state.isEmpty {
            message += " [SQLSTATE " + state + "]"
        }
        switch code {
        case 1045:
            return .authFailed("用户名或密码错误（1045 " + message + "）")
        case 1049:
            return .databaseNotExist("库 " + config.database + " 不存在，请先在服务端建库（1049 " + message + "）")
        case 1044:
            return .authFailed("账号无权访问库 " + config.database + "（1044 " + message + "）")
        case 1129:
            return .authFailed("主机被 MySQL 拒绝（1129），请检查账号的 host 授权：" + message)
        case 1698:
            return .authFailed("auth_socket 插件拒绝访问（1698）：" + message)
        case 1205, 1213:
            return .server(code: code, message: "锁等待/死锁，请重试：" + message)
        default:
            return .server(code: code, message: message)
        }
    }
}
