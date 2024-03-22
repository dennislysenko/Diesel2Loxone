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

@propertyWrapper
struct UserDefault<Value> {
    let key: String
    let defaultValue: Value
    var container: UserDefaults = .standard

    var wrappedValue: Value {
        get {
            return container.object(forKey: key) as? Value ?? defaultValue
        }
        set {
            container.set(newValue, forKey: key)
        }
    }
}


class LTOBD2PID_ODOMETER_A6: LTOBD2PID {}

struct ViewModel {
    var isServerRunning = false
    var isDeviceConnected = false
    var deviceState: String = "Uninitialized"

    var vin: String?
    var protocolVersion: String?
    
    var rpm: Int?
    var odometerReading: Int? // km
    var fuelRate: Double? // L/h
    var waterTemp: Int? // oC
    var fuelLevel: Double? // %, but as 0-100
    var tankCapacity: Double? // L
    
    var fuelInTank: Double? { // L
        guard let tankCapacity, let fuelLevel else { return nil }
        
        return Double(tankCapacity) * fuelLevel / 100
    }
}

class ViewController: UIViewController {
    let webServer = GCDWebServer()
    
    var player: AVAudioPlayer?

    var viewModel = ViewModel() {
        didSet {
            bind(viewModel)
        }
    }
    
    @UserDefault(key: "tankCapacity_", defaultValue: 50)
    var tankCapacity: Double
    
    @IBOutlet weak var serverStatusLabel: UILabel!
    @IBOutlet weak var serverAddressLabel: UILabel!
    @IBOutlet weak var deviceStatusLabel: UILabel!

    @IBOutlet weak var obdProtocolLabel: UILabel!
    @IBOutlet weak var vinLabel: UILabel!

    @IBOutlet weak var rpmLabel: UILabel!
    @IBOutlet weak var odometerLabel: UILabel!
    @IBOutlet weak var waterTempLabel: UILabel!
    
    @IBOutlet weak var tankCapacityField: UITextField!
    @IBOutlet weak var fuelRateLabel: UILabel!
    @IBOutlet weak var fuelInTankLabel: UILabel!

    override func viewDidLoad() {
        super.viewDidLoad()
        
        webServer.delegate = self
        webServer.addHandler(forMethod: "GET", path: "/readings", request: GCDWebServerRequest.self, processBlock: { [weak self] request in
            guard let self = self else {
                fatalError()
            }

            return GCDWebServerDataResponse(jsonObject: [
                "rpm": self.viewModel.rpm as Any,
                "odometer_reading": self.viewModel.odometerReading as Any,
                "fuel_rate": self.viewModel.fuelRate as Any,
                "user_specified_tank_capacity": self.viewModel.tankCapacity as Any,
                "fuel_level_percent": self.viewModel.fuelLevel as Any,
                "water_temp": self.viewModel.waterTemp as Any,
                "fuel_in_tank": self.viewModel.fuelInTank as Any,

                "device_state": self.viewModel.deviceState as Any,
                "protocol_version": self.viewModel.protocolVersion as Any,
                "vin": self.viewModel.vin as Any
            ])
        })

        startWebServer()
        
        setupAudioPlayer()
        
        viewModel.tankCapacity = tankCapacity
        tankCapacityField.text = String(tankCapacity)
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
        let odometer = LTOBD2PID_ODOMETER_A6.forMode1()
        let fuelRate = LTOBD2PID_ENGINE_FUEL_RATE_5E.forMode1()
        let coolantTemp = LTOBD2PID_COOLANT_TEMP_05.forMode1()
        let fuelLevel = LTOBD2PID_FUEL_TANK_LEVEL_2F.forMode1()

        guard let obd2Adapter else {
            fatalError()
        }
        
        let commands = [rpm, odometer, fuelRate, coolantTemp, fuelLevel]
        obd2Adapter.transmitMultipleCommands(commands, completionHandler: { [weak self] commands in
            DispatchQueue.main.async {
                self?.viewModel.rpm = Int(rpm.formattedResponse.replacingOccurrences(of: "\u{202F}rpm", with: ""))
                self?.viewModel.odometerReading = Int(odometer.formattedResponse)
                self?.viewModel.fuelRate = Double(fuelRate.formattedResponse.replacingOccurrences(of: "\u{202F}L/h", with: ""))
                self?.viewModel.waterTemp = Int(coolantTemp.formattedResponse.replacingOccurrences(of: "\u{202F}°C", with: ""))
                self?.viewModel.fuelLevel = Double(fuelLevel.formattedResponse.replacingOccurrences(of: "\u{202F}%", with: ""))
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: { [weak self] in
                    self?.updateSensorData()
                })
            }
        })
    }
    
    func adapterDidConnect() {
        guard let obd2Adapter else {
            fatalError()
        }
        
        let vin = LTOBD2PID_VIN_CODE_0902()
        let describeProtocol = LTOBD2CommandELM327_DESCRIBE_PROTOCOL.command()
        
        let commands = [vin, describeProtocol]
        obd2Adapter.transmitMultipleCommands(commands, completionHandler: { [weak self] commands in
            DispatchQueue.main.async {
                self?.viewModel.vin = vin.formattedResponse
                self?.viewModel.protocolVersion = describeProtocol.formattedResponse
            }
        })
        
        self.updateSensorData()
    }
    
    @objc func onAdapterChangedState(_ notification: NSNotification) {
        guard let obd2Adapter else {
            return
        }

        DispatchQueue.main.async { [self] in
            viewModel.deviceState = obd2Adapter.friendlyAdapterState.replacingOccurrences(of: "OBD2AdapterState", with: "")
            
            switch obd2Adapter.adapterState {
            case OBD2AdapterStateDiscovering: break
            case OBD2AdapterStateConnected:
                self.adapterDidConnect()
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
        }
    }
    
    func bind(_ viewModel: ViewModel) {
        serverStatusLabel.text = viewModel.isServerRunning ? "Running" : "Not Running"
        serverAddressLabel.text = webServer.serverURL?.absoluteString ?? "<unavailable>"
        deviceStatusLabel.text = viewModel.deviceState

        vinLabel.text = viewModel.vin
        obdProtocolLabel.text = viewModel.protocolVersion
        
        rpmLabel.text = viewModel.rpm == nil ? "<unavailable>" : String(viewModel.rpm!) + " rpm"
        odometerLabel.text = viewModel.odometerReading == nil ? "<unavailable>" : String(viewModel.odometerReading!) + " km"
        fuelRateLabel.text = viewModel.fuelRate == nil ? "<unavailable>" : String(viewModel.fuelRate!) + " L/h"
        waterTempLabel.text = viewModel.waterTemp == nil ? "<unavailable>" : String(viewModel.waterTemp!) + " °C"
        fuelInTankLabel.text = viewModel.fuelInTank == nil ? "<unavailable>" : String(viewModel.fuelInTank!) + " L"
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

extension ViewController: UITextFieldDelegate {
    func textFieldDidBeginEditing(_ textField: UITextField) {
        textField.selectAll(nil)
    }
    
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField == tankCapacityField {
            tankCapacity = Double(textField.text ?? "") ?? tankCapacity
            viewModel.tankCapacity = tankCapacity
            textField.text = String(tankCapacity)
            textField.endEditing(true)
        }
        
        return true
    }
}

