//
//  ReadingsService.swift
//  OBD2Loxone
//
//  Created by Dennis Lysenko on 3/26/24.
//

import Foundation

class ReadingsService {
    static let shared = ReadingsService()
    private init() {}
    
    // Always in a stable descending order (most recent first)
    @UserDefault(key: "readings", defaultValue: []) var readings: [OBDDataPoint]
    
    func addReading(_ reading: OBDDataPoint) {
        assert(Thread.isMainThread)
        let mostRecentTime = readings.first?.time ?? Date(timeIntervalSince1970: 0)
        guard let time = reading.time, time >= mostRecentTime else {
            print("IGNORING reading with earlier time than previous most recent reading:", reading)
            return
        }
        readings.insert(reading, at: 0)
    }
    
    // read only: threadsafe
    func getPast5MinutesOfReadings() -> [OBDDataPoint] {
        let readings = self.readings
        let fiveMinsAgo = Date().addingTimeInterval(-5 * 60)
        var past5MinReadings: [OBDDataPoint] = []
        for i in 0..<readings.count {
            let reading = readings[i]
            
            guard let time = reading.time else {
                continue
            }

            if time >= fiveMinsAgo {
                past5MinReadings.append(reading)
            } else {
                // got to times past 5 mins ago
                break
            }
        }
        
        return past5MinReadings
    }
    
    func clearReadings() {
        assert(Thread.isMainThread)
        readings = []
    }
}
