import Foundation

struct APIService {
    static let baseURL = "https://debitmycredit.azurewebsites.net/"

    static func login(email: String, password: String, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        // Create the login api url
        guard let url = URL(string: "\(baseURL)/login") else {
            print("Invalid URL")
            return
        }

        // Setup the POST API request
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Set the body parameters and attach them to the request
        let body: [String: Any] = [
            "email": email,
            "password": password
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            completion(.failure(error))
            return
        }

        // Send the API request with the body
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            guard let data = data else {
                completion(.failure(NSError(domain: "No data", code: 0)))
                return
            }

            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    completion(.success(json))
                } else {
                    completion(.failure(NSError(domain: "Invalid JSON", code: 0)))
                }
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }
    
    
}
