import Combine
import Foundation

enum AICallStatus: String {
    case never
    case success
    case failed
}

private enum AIUsageDefaultsKeys {
    static let lastCallStatus = "ai.usage.lastCallStatus"
    static let lastCallError = "ai.usage.lastCallError"
    static let lastCallDate = "ai.usage.lastCallDate"
    static let lastCallFolderName = "ai.usage.lastCallFolderName"
}

@MainActor
final class AIUsageStore: ObservableObject {
    static let shared = AIUsageStore()

    static let testFolderName = "com.spotify.client"

    @Published private(set) var lastCallStatus: AICallStatus
    @Published private(set) var lastCallError: String?
    @Published private(set) var lastCallDate: Date?
    @Published private(set) var lastCallFolderName: String?

    private let ud = UserDefaults.standard

    private init() {
        ud.register(defaults: [
            AIUsageDefaultsKeys.lastCallStatus: AICallStatus.never.rawValue
        ])
        if let raw = ud.string(forKey: AIUsageDefaultsKeys.lastCallStatus),
           let status = AICallStatus(rawValue: raw) {
            lastCallStatus = status
        } else {
            lastCallStatus = .never
        }
        lastCallError = ud.string(forKey: AIUsageDefaultsKeys.lastCallError)
        if ud.object(forKey: AIUsageDefaultsKeys.lastCallDate) != nil {
            lastCallDate = Date(timeIntervalSince1970: ud.double(forKey: AIUsageDefaultsKeys.lastCallDate))
        } else {
            lastCallDate = nil
        }
        lastCallFolderName = ud.string(forKey: AIUsageDefaultsKeys.lastCallFolderName)
    }

    func recordSuccess(folderName: String, date: Date = Date()) {
        lastCallStatus = .success
        lastCallError = nil
        lastCallDate = date
        lastCallFolderName = folderName
        persist()
    }

    func recordFailure(folderName: String, error: String, date: Date = Date()) {
        lastCallStatus = .failed
        lastCallError = error
        lastCallDate = date
        lastCallFolderName = folderName
        persist()
    }

    private func persist() {
        ud.set(lastCallStatus.rawValue, forKey: AIUsageDefaultsKeys.lastCallStatus)
        if let lastCallError {
            ud.set(lastCallError, forKey: AIUsageDefaultsKeys.lastCallError)
        } else {
            ud.removeObject(forKey: AIUsageDefaultsKeys.lastCallError)
        }
        if let lastCallDate {
            ud.set(lastCallDate.timeIntervalSince1970, forKey: AIUsageDefaultsKeys.lastCallDate)
        } else {
            ud.removeObject(forKey: AIUsageDefaultsKeys.lastCallDate)
        }
        if let lastCallFolderName {
            ud.set(lastCallFolderName, forKey: AIUsageDefaultsKeys.lastCallFolderName)
        } else {
            ud.removeObject(forKey: AIUsageDefaultsKeys.lastCallFolderName)
        }
    }
}
