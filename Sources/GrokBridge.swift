import Foundation
import Security
import CommonCrypto
import LocalAuthentication

struct GrokUsage {
    let remaining: Double
    let reset: Date?
}

final class GrokBridge {
    private let session = URLSession(configuration: .ephemeral)
    private let queue = DispatchQueue(label: "local.widget.grok")
    func read(completion: @escaping (Result<GrokUsage, Error>) -> Void) {
        queue.async {
            do {
                let token = try self.token()
                var request = URLRequest(url: URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus")!)
                request.httpMethod = "POST"; request.httpBody = Data("{}".utf8); request.timeoutInterval = 20
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
                request.setValue("true", forHTTPHeaderField: "x-ghost-mode")
                self.session.dataTask(with: request) { data, response, error in
                    let result: Result<GrokUsage, Error>
                    do {
                        if let error { throw error }
                        guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data else {
                            throw WidgetError.message("Grok 查询失败（\((response as? HTTPURLResponse)?.statusCode ?? 0)），请打开 Grok Bot 确认登录。")
                        }
                        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let used = (obj["usagePercent"] as? NSNumber)?.doubleValue else { throw WidgetError.message("Grok 尚未返回个人额度") }
                        var reset: Date?
                        if let stamp = obj["nextResetTimestampUtc"] as? String {
                            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                            reset = f.date(from: stamp)
                            if reset == nil { f.formatOptions = [.withInternetDateTime]; reset = f.date(from: stamp) }
                        }
                        result = .success(GrokUsage(remaining: max(0, min(100, 100-used)), reset: reset))
                    } catch { result = .failure(error) }
                    DispatchQueue.main.async { completion(result) }
                }.resume()
            } catch { DispatchQueue.main.async { completion(.failure(error)) } }
        }
    }
    private func token() throws -> String {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Grok Bot/sand-secrets.json")
        guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any],
              let accountsText = root["cursor-accounts"] as? String,
              let accountsData = accountsText.data(using: .utf8),
              let accounts = try JSONSerialization.jsonObject(with: accountsData) as? [String: Any],
              let active = accounts["active"] as? String,
              let slots = accounts["accounts"] as? [String: [String: Any]],
              var encoded = slots[active]?["cursor-access-token"] as? String else { throw WidgetError.message("请先登录 Grok Bot") }
        if encoded.hasPrefix("scoped:v1:") { encoded = encoded.split(separator: ":", maxSplits: 3).last.map(String.init) ?? "" }
        guard let encrypted = Data(base64Encoded: encoded), encrypted.starts(with: Data("v10".utf8)) else { throw WidgetError.message("Grok 登录存储格式暂不支持") }
        let context = LAContext(); context.interactionNotAllowed = true
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Grok Bot Safe Storage", kSecAttrAccount as String: "Grok Bot Key",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let password = item as? Data else { throw WidgetError.message("Grok 钥匙串暂不可读（\(status)）") }
        var key = [UInt8](repeating: 0, count: 16)
        let salt = Array("saltysalt".utf8)
        let derived = password.withUnsafeBytes { p in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), p.bindMemory(to: Int8.self).baseAddress, password.count, salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
        }
        guard derived == kCCSuccess else { throw WidgetError.message("无法读取 Grok 登录信息") }
        let cipher = Data(encrypted.dropFirst(3)); var plain = [UInt8](repeating: 0, count: cipher.count + 16); var count = 0
        let iv = [UInt8](repeating: 32, count: 16)
        let result = cipher.withUnsafeBytes { bytes in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), key, key.count, iv, bytes.baseAddress, cipher.count, &plain, plain.count, &count)
        }
        guard result == kCCSuccess, let text = String(bytes: plain.prefix(count), encoding: .utf8), !text.isEmpty else { throw WidgetError.message("无法解读 Grok 登录信息") }
        return text
    }
}
