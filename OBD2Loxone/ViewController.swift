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
    var deviceState: String = "Uninitialized"
    var rpm: Int?
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
    @IBOutlet weak var deviceStatusLabel: UILabel!
    @IBOutlet weak var rpmLabel: UILabel!

    override func viewDidLoad() {
        super.viewDidLoad()
        
        webServer.delegate = self
        webServer.addHandler(forMethod: "GET", path: "/rpm", request: GCDWebServerRequest.self, processBlock: { [weak self] request in
            guard let self = self else {
                fatalError()
            }

            return GCDWebServerDataResponse(jsonObject: ["rpm": self.viewModel.rpm])
        })

        startWebServer()
        
        setupAudioPlayer()
        
        bind(viewModel)

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleAudioSessionInterruption),
                                               name: AVAudioSession.interruptionNotification,
                                               object: AVAudioSession.sharedInstance())
        
        NotificationCenter.default.addObserver(self, selector: #selector(onAdapterChangedState), name: NSNotification.Name(rawValue: LTOBD2AdapterDidUpdateState), object: nil)
        
        connectToAdapter()
    }

    var pids: [LTOBD2Command] = []
    var transporter: LTBTLESerialTransporter?
    var obd2Adapter: LTOBD2AdapterELM327?
    func connectToAdapter() {
        var commandArray: [LTOBD2Command] = []
        commandArray.append(contentsOf: [
            LTOBD2CommandELM327_IDENTIFY.command(),
            LTOBD2CommandELM327_IGNITION_STATUS.command(),
            LTOBD2CommandELM327_READ_VOLTAGE.command(),
            LTOBD2CommandELM327_DESCRIBE_PROTOCOL.command(),
            
            LTOBD2PID_VIN_CODE_0902(),
            
            LTOBD2PID_ENGINE_RPM_0C.forMode1()
        ])
        
        self.pids = commandArray
        
        deviceStatusLabel.text = "Looking for adapter..."
        
        let transporter = LTBTLESerialTransporter(identifier: nil, serviceUUIDs: [CBUUID(string: "FFF0"), CBUUID(string: "FFE0"), CBUUID(string: "BEEF"), CBUUID(string: "E7810A71-73AE-499D-8C15-FAA9AEF0C3F2")])
        self.transporter = transporter
        
        transporter.connect { [weak self] inputStream, outputStream in
            guard let inputStream, let outputStream else {
                print("Null input stream")
                self?.deviceStatusLabel.text = "Could not connect"
                return
            }
            
            self?.obd2Adapter = LTOBD2AdapterELM327(inputStream: inputStream, outputStream: outputStream)
            self?.obd2Adapter?.connect()
        }
        
        transporter.startUpdatingSignalStrength(withInterval: 1.0)
    }
    
    func disconnectAdapter() {
        obd2Adapter?.disconnect()
        transporter?.disconnect()
    }
    
    // updates sensor data in a loop
    func updateSensorData() {
        let rpm = LTOBD2PID_ENGINE_RPM_0C.forMode1()
        guard let obd2Adapter else {
            fatalError()
        }
        
        obd2Adapter.transmitMultipleCommands([rpm], completionHandler: { [weak self] commands in
            DispatchQueue.main.async {
                self?.viewModel.rpm = Int(rpm.formattedResponse.replacingOccurrences(of: "\u{202F}rpm", with: ""))
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: { [weak self] in
                    self?.updateSensorData()
                })
            }
        })
    }
    
    @objc func onAdapterChangedState(_ notification: NSNotification) {
        guard let obd2Adapter else {
            return
        }

        DispatchQueue.main.async { [self] in
            viewModel.deviceState = obd2Adapter.friendlyAdapterState.replacingOccurrences(of: "OBD2AdapterState", with: "")
            
            switch obd2Adapter.adapterState {
            case OBD2AdapterStateDiscovering, OBD2AdapterStateConnected:
                self.updateSensorData()
            case OBD2AdapterStateGone:
                break // handle being gone?
            case OBD2AdapterStateUnsupportedProtocol:
                // adapter ready, but vehicle uses an unsupported protocol
                viewModel.deviceState = "UnsupportedProtocol(\(obd2Adapter.friendlyVehicleProtocol))"
            default:
                print("Unhandled adapter state", obd2Adapter.friendlyAdapterType)
            }
        }
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
        deviceStatusLabel.text = viewModel.deviceState
        rpmLabel.text = viewModel.rpm == nil ? "<unavailable>" : String(viewModel.rpm!) + " rpm"
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

