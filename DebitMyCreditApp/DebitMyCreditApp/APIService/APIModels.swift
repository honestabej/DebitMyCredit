import Foundation

class APIModels {
    // MARK: General models
    struct EmptyBody: Codable {}
    
    struct GenericResponse: Codable {
        let success: Bool?
        let message: String?
        let updatedAt: String?
    }
    
    // MARK: Authentication (login) req/rec models
    struct AuthRequest: Codable {
        let email: String
        let password: String
    }
    
    struct AuthResponse: Codable {
        let success: Bool?
        let token: String?
        let user: UserData?
        let message: String?
        let error: String?
        
        struct UserData: Sendable, Codable {
            let id: String
            let email: String
            let lastSimpleFinSync: String?
            let simpleFINConnected: Bool?
            let createdAt: String?
            let updatedAt: String?
        }
    }
    
    // MARK: General model to contain all user data from server
    struct UserDataResponse: Codable {
        let success: Bool
        let user: UserInfo?
        let accounts: [Account]
        let transactions: [Transaction]
        let transferGroups: [TransferGroup]
        
        struct UserInfo: Codable {
            let id: String
            let email: String
            let simpleFINConnected: IntOrBool?
            let createdAt: FlexibleDate?
            let updatedAt: FlexibleDate?
            
            /// Convenience property to get boolean value
            var isSimpleFINConnected: Bool {
                switch simpleFINConnected {
                case .int(let value):
                    return value == 1
                case .bool(let value):
                    return value
                case .none:
                    return false
                }
            }
        }
        
        struct Transaction: Codable {
            let id: String
            let accountID: String
            let amount: Double
            let name: String
            let transactionDate: FlexibleDate
            let pending: Bool
            let createdAt: FlexibleDate?
            let updatedAt: FlexibleDate?
        }
        
        struct TransferGroup: Codable {
            let id: String
            let name: String
            let createdAt: FlexibleDate?
            let updatedAt: FlexibleDate?
        }
    }
    
    struct UserDataRequest: Codable {
        let newEmail: String?
        let newPassword: String?
    }
    
    // MARK: SimpleFIN Connection req/rec models
    struct SimpleFINConnectionRequest: Codable {
        let userID: UUID
        let setupToken: String
    }
    
    struct SimpleFINConnectionResponse: Codable {
        let success: Bool?
        let message: String?
        let accounts: [Account]?
    }
    
    struct SimpleFINDeletionRequest: Codable {
        let userID: UUID
    }
        
    // MARK: Account req/rec models
    struct Account: Codable {
        let id: String
        let name: String
        let bank: String
        let accountNumber: String?
        let accountBalance: Double
        let accountType: String?
        let balanceDate: FlexibleDate?
        let createdAt: FlexibleDate?
        let updatedAt: FlexibleDate?
        
        /// Converts the SimpleFINAccount to a dictionary format expected by CoreDataService
        var toDictionary: [String: Any] {
            var data: [String: Any] = [
                "id": id,
                "name": name,
                "bank": bank,
                "accountBalance": accountBalance
            ]
            
            if let accountType = accountType {
                data["accountType"] = accountType
            }
            
            if let balanceDate = balanceDate?.stringValue {
                data["balanceDate"] = balanceDate
            }
            
            if let createdAt = createdAt?.stringValue {
                data["createdAt"] = createdAt
            }
            
            if let updatedAt = updatedAt?.stringValue {
                data["updatedAt"] = updatedAt
            }
            
            return data
        }
    }
    
    struct AccountsResponse: Codable {
        let success: Bool
        let accounts: [Account]
    }
    
    struct AccountsToUpdateRequest: Codable {
        let userID: UUID
        let accounts: [Account]
    }
    
    struct AccountsToUpdateResponse: Codable {
        let success: Bool?
        let message: String?
        let accountsUpdated: Int?
    }
    
    // MARK: Status of server and DB model
    struct StatusResponse: Codable {
        let server: ServerStatus
        let database: DatabaseStatus
        let overall: String
        
        struct ServerStatus: Codable {
            let status: String
            let timestamp: String
        }
        
        struct DatabaseStatus: Codable {
            let status: String
            let message: String
            let responseTime: String?
            let attempts: Int
            let error: String?
        }
        
        /// Convenience properties
        var isHealthy: Bool {
            overall == "healthy"
        }
        
        var isDatabaseUp: Bool {
            database.status == "up"
        }
        
        var isServerUp: Bool {
            server.status == "up"
        }
        
        /// Human-readable status description
        var statusDescription: String {
            if isHealthy {
                if database.attempts == 1 {
                    return "All systems operational"
                } else {
                    return "Systems operational (DB took \(database.attempts) attempts to connect)"
                }
            } else {
                return "Database unavailable after \(database.attempts) attempts"
            }
        }
    }
    
    
    // MARK: Helper functions for model decoding
    // Decode dates that might come in various formats
    enum FlexibleDate: Codable {
        case string(String)
        case date(Date)
        
        var stringValue: String? {
            switch self {
            case .string(let str):
                return str
            case .date(let date):
                let formatter = ISO8601DateFormatter()
                return formatter.string(from: date)
            }
        }
        
        var dateValue: Date? {
            switch self {
            case .string(let str):
                // Handle Azure's 7-digit fractional seconds format (e.g. "2026-03-31T15:54:25.0000000-07:00")
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSSxxxxx"
                if let date = formatter.date(from: str) { return date }
                // Fall back to standard ISO8601 for other formats
                let isoFormatter = ISO8601DateFormatter()
                isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return isoFormatter.date(from: str)
            case .date(let date):
                return date
            }
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            
            // Try string first (most common from API)
            if let stringValue = try? container.decode(String.self) {
                self = .string(stringValue)
                return
            }
            
            // Try date
            if let dateValue = try? container.decode(Date.self) {
                self = .date(dateValue)
                return
            }
            
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected String or Date"
            )
        }
        
        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value):
                try container.encode(value)
            case .date(let value):
                try container.encode(value)
            }
        }
    }
    
    // Decode boolean that might come as 0/1 integer from SQL
    enum IntOrBool: Codable {
        case int(Int)
        case bool(Bool)
        
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            
            // Try to decode as Int first (SQL returns 0/1)
            if let intValue = try? container.decode(Int.self) {
                self = .int(intValue)
                return
            }
            
            // Fall back to Bool
            if let boolValue = try? container.decode(Bool.self) {
                self = .bool(boolValue)
                return
            }
            
            // If neither works, default to false
            self = .bool(false)
        }
        
        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .int(let value):
                try container.encode(value)
            case .bool(let value):
                try container.encode(value)
            }
        }
    }
    
    struct SyncResponse: Codable {
        let success: Bool
        let message: String
    }
}
