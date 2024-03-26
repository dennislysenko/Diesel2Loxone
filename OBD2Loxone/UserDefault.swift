//
//  UserDefault.swift
//  OBD2Loxone
//
//  Created by Dennis Lysenko on 3/26/24.
//

import Foundation

// https://dev.to/andresr173/userdefaults-and-property-wrappers-in-swift-10dn
@propertyWrapper
struct UserDefault<Value: Codable> {
    let key: String
    let defaultValue: Value
    let userDefaults = UserDefaults.standard

    var wrappedValue: Value {
        get {
            let data = userDefaults.data(forKey: key)
            let value = data.flatMap { try? JSONDecoder().decode(Value.self, from: $0) }
            return value ?? defaultValue
        }

        set {
            let data = try? JSONEncoder().encode(newValue)
            userDefaults.set(data, forKey: key)
            userDefaults.synchronize()
        }
    }
}
