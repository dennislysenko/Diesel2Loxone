//
//  ViewController.swift
//  OBD2Loxone
//
//  Created by Dennis Lysenko on 3/21/24.
//

import UIKit
import GCDWebServer
import LTSupportAutomotive
import AVFoundation

struct ViewModel {
    var isServerRunning = false
    var isDeviceConnected = false
    var lastFuelReading = 110
}

class ViewController: UIViewController {
    let webServer = GCDWebServer()
    
    var player: AVAudioPlayer?

    var viewModel = ViewModel() {
        didSet {
            bind(viewModel)
        }
    }
    
    @IBOutlet weak var serverStatusLabel: UILabel!
    @IBOutlet weak var serverAddressLabel: UILabel!

    override func viewDidLoad() {
        super.viewDidLoad()
        
        webServer.delegate = self
//        webServer.addDefaultHandler(forMethod: "GET", request: GCDWebServerRequest.self, processBlock: {request in
//            return GCDWebServerDataResponse(html:"<html><body><p>Hello World</p></body></html>")
//        })
        webServer.addHandler(forMethod: "GET", path: "/fuel_reading", request: GCDWebServerRequest.self, processBlock: { [weak self] request in
            guard let self = self else {
                fatalError()
            }

            // return viewModel.lastFuelReading in JSON result {"last_fuel_reading": 110}
            return GCDWebServerDataResponse(jsonObject: ["last_fuel_reading": self.viewModel.lastFuelReading])
        })

        startWebServer()
        
        setupAudioPlayer()
        
        bind(viewModel)

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleAudioSessionInterruption),
                                               name: AVAudioSession.interruptionNotification,
                                               object: AVAudioSession.sharedInstance())
    }

    @objc func handleAudioSessionInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
            let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
                return
        }

        if type == .began {
            // Interruption began, pause the audio
            player?.pause()
        } else if type == .ended {
            // Interruption ended, resume the audio
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    player?.play()
                }
            }
        }
    }

    func setupAudioPlayer() {
        guard let filePath = Bundle.main.path(forResource: "silence", ofType: "wav") else { return }
        let fileURL = URL(fileURLWithPath: filePath)

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            player = try AVAudioPlayer(contentsOf: fileURL, fileTypeHint: AVFileType.mp3.rawValue)
            
            guard let player = player else { return }
            player.numberOfLoops = -1 // Loop indefinitely
            player.play()
            
            print("Playing audio")
        } catch let error {
            print(error.localizedDescription)
        }
    }
    
    func startWebServer() {
        Task {
            // webServer.start(withPort: 8080, bonjourName: "GCD Web Server")
            try! webServer.start(options: [
                GCDWebServerOption_Port: 8080,
                GCDWebServerOption_BonjourName: "OBD2Loxone Server",
                GCDWebServerOption_AutomaticallySuspendInBackground: NSNumber(value: false)
            ])
            print("Visit \(webServer.serverURL) in your web browser")
        }
    }
    
    func bind(_ viewModel: ViewModel) {
        serverStatusLabel.text = viewModel.isServerRunning ? "Running" : "Not Running"
        serverAddressLabel.text = webServer.serverURL?.absoluteString ?? "<unavailable>"
    }
}

extension ViewController: GCDWebServerDelegate {
    func webServerDidStart(_ server: GCDWebServer) {
        viewModel.isServerRunning = true
    }
    
    func webServerDidStop(_ server: GCDWebServer) {
        viewModel.isServerRunning = false
    }
}

