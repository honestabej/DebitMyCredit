import Foundation

// Possible errors that the method can throw
enum APIError: LocalizedError, Equatable {
    case invalidURL
    case noData
    case invalidResponse
    case dbAsleep
    case decodingFailed
    case requestFailed
    case httpError(statusCode: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .noData:
            return "No data received from server"
        case .invalidResponse:
            return "Invalid response from server"
        case .dbAsleep:
            return "DB is waking up, please wait..."
        case .decodingFailed:
            return "Failed to decode response"
        case .requestFailed:
            return "Request failed"
        case .httpError(let statusCode, let message):
            return message ?? "HTTP Error \(statusCode)"
        }
    }
}

// Possible HTTP Request methods
enum HTTPMethod: String {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
    case patch = "PATCH"
}

class APIService {
    static let shared = APIService()
    
    private let baseURL = "https://debitmycredit.azurewebsites.net"
//    private let baseURL = "http://localhost:3000"
    private let session: URLSession
    
    // Conifgure retry settings for waking server and/or AzureDB
    private let maxRetries = 4
    private let retryDelay: TimeInterval = 6.0
    private let serverWakeupDelay: TimeInterval = 10.0
    
    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 150
        self.session = URLSession(configuration: configuration)
    }
    
    // MARK: Reusable function to inititaite API calls
    func makeRequest<T: Decodable>(
        endpoint: String = "/",
        method: HTTPMethod = .get,
        body: (any Encodable)? = nil,
        retryCount: Int = 0,
        token: String? = nil
    ) async throws -> T {
        print("[APIService] Initiating request to \(baseURL)\(endpoint)")
        
        // Build URL
        guard let url = URL(string: "\(baseURL)\(endpoint)") else {
            print("└─ Invalid URL")
            throw APIError.invalidURL
        }
        
        // Create URL Request
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Add body if provided
        if let body = body {
            request.httpBody = try JSONEncoder().encode(body)
            print("├─ Body encoded and attached")
        }
        
        // Add JWT Authorization if provided
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            print("├─ Auth token attached")
        }
        
        do {
            // Make request
            print("├─ Request sent, awaiting response...")
            let (data, response) = try await session.data(for: request)
            
            // Ensure the server sent data back in the response
            if data.isEmpty {
                throw APIError.noData
            }
            
            // Validate response
            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            
            print("├─ Response status: \(httpResponse.statusCode)")

            // Check for any indication that the DB may be asleep
            if isDBAsleep(data: data, statusCode: httpResponse.statusCode) {
                print("├─ DB detected as sleeping")
                throw APIError.dbAsleep
            }
            
            guard (200...299).contains(httpResponse.statusCode) else {
                let errorMessage = try? JSONDecoder().decode([String: String].self, from: data)["message"]
                print("└─ HTTP Error \(httpResponse.statusCode): \(errorMessage ?? "No message")")
                throw APIError.httpError(statusCode: httpResponse.statusCode, message: errorMessage ?? "Unknown Server Error")
            }
            
            // Decode response
            do {
                let decoded = try JSONDecoder().decode(T.self, from: data)
                print("└─ Success! Response decoded successfully")
                return decoded
            } catch {
                print("├─ Decoding failed: \(error.localizedDescription)")
                print("└─ Raw response: \(String(data: data, encoding: .utf8) ?? "Unable to read")")
                throw APIError.decodingFailed
            }
            
         } catch let error as APIError where error == .dbAsleep {
            // Retry logic for sleeping server
            if retryCount < maxRetries {
                let delay = retryCount == 0 ? serverWakeupDelay : retryDelay
                print("└─ DB asleep. Will retry in \(delay)s (Attempt \(retryCount + 1)/\(maxRetries))")
                
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                return try await makeRequest(endpoint: endpoint, method: method, body: body, retryCount: retryCount + 1, token: token)
            } else {
                print("└─ Max retries (\(maxRetries)) reached. Giving up.")
                throw error
            }
        } catch {
            // Retry on network errors (likely server cold start on first attempt)
            if retryCount < maxRetries && isRetryableError(error) {
                // Use longer delay for first retry (likely cold start)
                let delay = retryCount == 0 ? serverWakeupDelay : retryDelay
                let errorType = (error as NSError).code == NSURLErrorTimedOut ? "Timeout (likely cold start)" : "Network error"
                
                print("└─ \(errorType). Will retry in \(delay)s (Attempt \(retryCount + 1)/\(maxRetries))")
                
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                return try await makeRequest(endpoint: endpoint, method: method, body: body, retryCount: retryCount + 1, token: token)
            } else {
                print("└─ Request failed: \(error.localizedDescription)")
                throw error
            }
        }
    }
    
    // MARK: - Helper Methods
    private func isDBAsleep(data: Data, statusCode: Int) -> Bool {
        // Azure may return specific messages or status codes when server is sleeping
        // 500, 502, 503 are all indicators of server sleep/startup
        if statusCode == 500 || statusCode == 503 || statusCode == 502 {
            return true
        }

        // Check for specific Azure sleep messages in response
        if let responseString = String(data: data, encoding: .utf8) {
            let sleepIndicators = [
                "service unavailable",
                "starting",
                "cold start",
                "warming up",
                "internal server error", // Azure sometimes returns this when waking
                "application error",
                "temporarily unavailable",
                "databaseunavailable", // Database waking up
                "database is starting up", // Custom server message
                "failed to connect", // Database connection errors
                "connectionerror" // Database connection timeout
            ]
            let lowercaseResponse = responseString.lowercased()
            return sleepIndicators.contains { lowercaseResponse.contains($0) }
        }

        return false
    }

    private func isRetryableError(_ error: Error) -> Bool {
        // Retry on network errors, timeouts, etc.
        let nsError = error as NSError

        // URLError codes that should be retried
        let retryableURLErrorCodes: [Int] = [
            NSURLErrorTimedOut,
            NSURLErrorCannotConnectToHost,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorNotConnectedToInternet,
            NSURLErrorCannotFindHost,
            NSURLErrorCannotLoadFromNetwork
        ]

        // Treat timeouts and connection errors as potential server sleep
        return nsError.domain == NSURLErrorDomain && retryableURLErrorCodes.contains(nsError.code)
    }
    
    // MARK: API Endpoint Calls
    // Register a new user
    func register(email: String, password: String) async throws -> APIModels.AuthResponse {
        let body = APIModels.AuthRequest(email: email, password: password)
        return try await makeRequest(endpoint: "/register", method: .post, body: body)
    }

    // Login an existing user
    func login(email: String, password: String) async throws -> APIModels.AuthResponse {
        let body = APIModels.AuthRequest(email: email, password: password)
        return try await makeRequest(endpoint: "/login", method: .post, body: body)
    }
    
    // Update User Account info
    func updateUserAccountInfo(email: String?, password: String?, token: String) async throws -> APIModels.GenericResponse {
        let body = APIModels.UserDataRequest(newEmail: email, newPassword: password)
        return try await makeRequest(endpoint: "/update/user", method: .post, body: body, token: token)
    }

    // Connect SimpleFin Account
    func connectSimpleFin(userID: UUID, setupToken: String) async throws -> APIModels.SimpleFINConnectionResponse {
        let body = APIModels.SimpleFINConnectionRequest(userID: userID, setupToken: setupToken)
        return try await makeRequest(endpoint: "/connect-simplefin", method: .post, body: body)
    }

    // Disconnect a SimpleFIN account
    func disconnectSimpleFin(userID: UUID) async throws -> APIModels.GenericResponse {
        let body = APIModels.SimpleFINDeletionRequest(userID: userID)
        return try await makeRequest(endpoint: "/disconnect-simplefin", method: .post, body: body)
    }

    // Get all connected bank accounts of a user
    func fetchAccounts(token: String) async throws -> APIModels.AccountsResponse {
        return try await makeRequest(endpoint: "/accounts", method: .get, token: token)
    }
    
    // Update name/type of account
    func updateAccountInfo(userID: UUID, token: String, accounts: [APIModels.Account]) async throws -> APIModels.AccountsToUpdateResponse {
        let body = APIModels.AccountsToUpdateRequest(userID: userID, accounts: accounts)
        return try await makeRequest(endpoint: "/update/accounts", method: .post, body: body, token: token)
    }

    // Get server and database status
    func getStatus() async throws -> APIModels.StatusResponse {
        return try await makeRequest(endpoint: "/status", method: .get)
    }

    // Fetch all user data (accounts, transactions, transfer groups)
    func fetchUserData(token: String) async throws -> APIModels.UserDataResponse {
        return try await makeRequest(endpoint: "/user/data", method: .get, token: token)
    }

    // Trigger background sync for authenticated user
    func syncSimpleFIN(token: String) async throws -> APIModels.SyncResponse {
        return try await makeRequest(endpoint: "/user/sync", method: .post, token: token)
    }
}















































// MARK: - Old Request Method
//    private func request<T: Decodable & Sendable>(endpoint: String, method: HTTPMethod = .get, body: (any Encodable & Sendable)? = nil, retryCount: Int = 0, token: String? = nil) async throws -> T {
//        let attemptLabel = retryCount == 0 ? "Initial" : "Retry #\(retryCount)"
//        
//        print("\n [\(attemptLabel)] API Request")
//        print("├─ Endpoint: \(method.rawValue) \(baseURL)\(endpoint)")
//        print("├─ Time: \(Date().formatted(date: .omitted, time: .standard))")
//        
//        // Build URL
//        guard let url = URL(string: "\(baseURL)\(endpoint)") else {
//            print("└─ Invalid URL")
//            throw APIError.invalidURL
//        }
//        
//        // Create request
//        var urlRequest = URLRequest(url: url)
//        urlRequest.httpMethod = method.rawValue
//        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
//        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
//        
//        // Add body if provided
//        if let body = body {
//            urlRequest.httpBody = try JSONEncoder().encode(body)
//            print("├─ Body: Present (encoded)")
//        }
//        
//        // Add authorization if provided
//        if let token, !token.isEmpty {
//            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
//            print("├─ Auth: Bearer token attached")
//        }
//        
//        do {
//            print("├─ Sending request...")
//            let startTime = Date()
//            
//            // Perform request
//            let (data, response) = try await session.data(for: urlRequest)
//            
//            let duration = Date().timeIntervalSince(startTime)
//            print("├─ Response received in \(String(format: "%.2f", duration))s")
//            
//            // Validate response
//            guard let httpResponse = response as? HTTPURLResponse else {
//                print("└─ Invalid response type")
//                throw APIError.invalidResponse
//            }
//            
//            print("├─ Status: \(httpResponse.statusCode)")
//            
//            // Check for any indication that the DB may be asleep
//            if isDBAsleep(data: data, statusCode: httpResponse.statusCode) {
//                print("├─ DB detected as sleeping/waking")
//                throw APIError.dbAsleep
//            }
//            
//            // Check for other HTTP errors
//            guard (200...299).contains(httpResponse.statusCode) else {
//                let errorMessage = try? JSONDecoder().decode([String: String].self, from: data)["message"]
//                print("└─ HTTP Error \(httpResponse.statusCode): \(errorMessage ?? "No message")")
//                throw APIError.httpError(statusCode: httpResponse.statusCode, message: errorMessage)
//            }
//            
//            // Decode response
//            do {
//                let decoder = JSONDecoder()
//                // Use default decoding - FlexibleDate will handle strings
//                
//                let decoded = try decoder.decode(T.self, from: data)
//                print("└─ Success! Response decoded successfully")
//                return decoded
//            } catch let DecodingError.keyNotFound(key, context) {
//                print("├─ Decoding failed: Missing key '\(key.stringValue)'")
//                print("├─ Context: \(context.debugDescription)")
//                print("├─ Coding path: \(context.codingPath.map { $0.stringValue }.joined(separator: " -> "))")
//                print("└─ Raw response: \(String(data: data, encoding: .utf8) ?? "Unable to read")")
//                throw APIError.decodingFailed
//            } catch let DecodingError.typeMismatch(type, context) {
//                print("├─ Decoding failed: Type mismatch for \(type)")
//                print("├─ Context: \(context.debugDescription)")
//                print("├─ Coding path: \(context.codingPath.map { $0.stringValue }.joined(separator: " -> "))")
//                print("└─ Raw response: \(String(data: data, encoding: .utf8) ?? "Unable to read")")
//                throw APIError.decodingFailed
//            } catch {
//                print("├─ Decoding failed: \(error.localizedDescription)")
//                print("└─ Raw response: \(String(data: data, encoding: .utf8) ?? "Unable to read")")
//                throw APIError.decodingFailed
//            }
//            
//        } catch let error as APIError where error == .dbAsleep {
//            // Retry logic for sleeping server
//            if retryCount < maxRetries {
//                let delay = retryCount == 0 ? serverWakeupDelay : retryDelay
//                print("└─ DB asleep. Will retry in \(delay)s (Attempt \(retryCount + 1)/\(maxRetries))")
//                
//                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
//                return try await request(endpoint: endpoint, method: method, body: body, retryCount: retryCount + 1)
//            } else {
//                print("└─ Max retries (\(maxRetries)) reached. Giving up.")
//                throw error
//            }
//        } catch {
//            // Retry on network errors (likely server cold start on first attempt)
//            if retryCount < maxRetries && isRetryableError(error) {
//                // Use longer delay for first retry (likely cold start)
//                let delay = retryCount == 0 ? serverWakeupDelay : retryDelay
//                let errorType = (error as NSError).code == NSURLErrorTimedOut ? "Timeout (likely cold start)" : "Network error"
//                
//                print("└─ \(errorType). Will retry in \(delay)s (Attempt \(retryCount + 1)/\(maxRetries))")
//                
//                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
//                return try await request(endpoint: endpoint, method: method, body: body, retryCount: retryCount + 1)
//            } else {
//                print("└─ Request failed: \(error.localizedDescription)")
//                throw error
//            }
//        }
//    }
