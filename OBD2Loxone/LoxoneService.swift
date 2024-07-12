//
//  LoxoneService.swift
//  OBD2Loxone
//
//  Created by Dennis Lysenko on 4/5/24.
//

import Foundation
import Alamofire

protocol LoxoneServiceDelegate: AnyObject {
    func didUpdateSpareTankValue(_ value: Double)
}

class LoxoneService: NSObject {
    weak var delegate: LoxoneServiceDelegate?
    
    var isFetching = false
    
    static let shared = LoxoneService()
    private override init() {}
    
    @UserDefault(key: "miniserverURL", defaultValue: "http://dns.loxonecloud.com/504F94A22C3E/jdev/sps/io/1cacccf8-0381-409f-ffffb3ee168149c6/state")
    var miniserverURL: String
    
    enum Errors: Error {
        case invalidMiniserverURL(String)
    }
    
    func getBase64LoginString() -> String {
        let username = "test"
        let password = "Test123"

        let loginString = String(format: "%@:%@", username, password)
        let loginData = loginString.data(using: String.Encoding.utf8)!
        return loginData.base64EncodedString()
    }
    
    func fetchSpareTankValue() {
//        isFetching = true
//        
//        Task {
//            let response = await AF.request(miniserverURL)
//                .authenticate(username: "test", password: "Test123")
//                .redirect(using: .follow)
//                .validate()
//                .cURLDescription {
//                    print($0)
//                }
//                .responseDecodable(of: LoxoneParameterResponse.self) { response in
//                    switch response.result {
//                    case .success(let response):
//                        let stringWithoutLiter = response.LL.value.replacingOccurrences(of: " Liter", with: "")
//                        if let doubleValue = Double(stringWithoutLiter) {
//                            self.delegate?.didUpdateSpareTankValue(doubleValue)
//                        } else {
//                            print("No liter value in \(stringWithoutLiter)")
//                        }
//                    case .failure(let error):
//                        print(error.localizedDescription)
//                    }
//                }
//                .response
//            
//            debugPrint(response)
//        }
//        
//        return ()
        guard let url = URL(string: miniserverURL) else {
            return
        }

        isFetching = true

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // request.setValue("Basic \(getBase64LoginString())", forHTTPHeaderField: "Authorization")
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data, error == nil else {
                print(error?.localizedDescription ?? "No data")
                return
            }
            
            self.handleTankResponseData(data)
        }
        task.delegate = self
        task.resume()
    }
    
    func makeSecondRequest(to url: URL) {
        var request = URLRequest(url: url)
        request.setValue("Basic \(getBase64LoginString())", forHTTPHeaderField: "Authorization")
        
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data, error == nil else {
                print(error?.localizedDescription ?? "No data")
                return
            }
            
            self.handleTankResponseData(data)
        }
        
        task.resume()
    }
    
    struct LoxoneParameterResponse: Codable {
        struct InnerStruct: Codable {
            let value: String
        }
        
        let LL: InnerStruct
    }
    
    func handleTankResponseData(_ data: Data) {
        // response is like this
        // {"LL": { "control": "dev/sps/io/1cacccf8-0381-409f-ffffb3ee168149c6/state", "value": "31.0 Liter", "Code": "200"}}
        // we want the 31.0 value as a double
        
        guard
            let responseJSON = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
            let value = responseJSON["LL"] as? [String: Any],
            let value = value["value"] as? String,
            let doubleValue = Double(value) 
        else {
            print("!!! Failed to decode tank response:", String(data: data, encoding: .utf8) ?? "<none>")
            return
        }
        
        DispatchQueue.main.async {
            self.delegate?.didUpdateSpareTankValue(doubleValue)
        }
    }
}

extension LoxoneService: URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
//        var newRequest = request
        // Reapply the basic auth (if necessary) or modify the request as needed
//        let username = "test"
//        let password = "Test123"
//        let loginString = "\(username):\(password)"
//        let loginData = loginString.data(using: .utf8)!
//        let base64LoginString = loginData.base64EncodedString()
//        newRequest.setValue("Basic \(base64LoginString)", forHTTPHeaderField: "Authorization")
//        
//        return newRequest
        
        print(request.url?.absoluteString ?? "No URL")
        makeSecondRequest(to: request.url!)
        return nil
    }
}


