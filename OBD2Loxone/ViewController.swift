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
import CoreLocation
import OSLog

struct ViewModel {
    var isServerRunning = false
    var isDeviceConnected = false
    var deviceState: String = "Uninitialized"
    
    var lastKnownLatitude: Double?
    var lastKnownLongitude: Double?
    var lastKnownElevation: Double?

    var vin: String?
    var protocolVersion: String?
    
    var baseDistance: Double? = 2000
    var tankCapacity: Double?
    
    var obdData: OBDDataPoint?
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
    var savedTankCapacity: Double
    
//    @UserDefault(key: "baseDistance__", defaultValue: 0)
//    var savedBaseDistance: Double
    
    let locationManager = CLLocationManager()
    
    let readingsService = ReadingsService.shared
    
    @IBOutlet weak var serverStatusLabel: UILabel!
    @IBOutlet weak var serverAddressLabel: UILabel!
    @IBOutlet weak var deviceStatusLabel: UILabel!

    @IBOutlet weak var obdProtocolLabel: UILabel!
    @IBOutlet weak var vinLabel: UILabel!

    @IBOutlet weak var rpmLabel: UILabel!
    @IBOutlet weak var odometerLabel: UILabel!
    @IBOutlet weak var waterTempLabel: UILabel!
    
    @IBOutlet weak var tankCapacityField: UITextField!
    @IBOutlet weak var odometerTextField: UITextField!
    @IBOutlet weak var odometerActionButton: UIButton!
    @IBOutlet weak var odometerCancelButton: UIButton!
    
    @IBOutlet weak var spareTankLabel: UILabel!
    @IBOutlet weak var miniserverTextField: UITextField!
    @IBOutlet weak var miniserverActionButton: UIButton!
    @IBOutlet weak var miniserverCancelButton: UIButton!
    
    @IBOutlet weak var fuelRateLabel: UILabel!
    @IBOutlet weak var engineLoadLabel: UILabel!
    @IBOutlet weak var fuelInTankLabel: UILabel!
    
    var miniserverTimer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        
        let logStore = try! OSLogStore(scope: .currentProcessIdentifier)
            
        // Define a time interval (e.g., the last hour)
        let oneHourAgo = Date().addingTimeInterval(-3600)
        let dateInterval = DateInterval(start: oneHourAgo, end: Date())
        
        let subsystem = "com.ltsupportautomotive.log"
        let predicate = NSPredicate(format: "subsystem == %@", subsystem)
        
        // Retrieve log entries
        let entries = try! logStore.getEntries()
        
        // Process and format the entries into a string
        let logMessages = entries.map { entry -> String in
            let dateFormatter = ISO8601DateFormatter()
            let timestamp = dateFormatter.string(from: entry.date)
            return "\(timestamp): \(entry.composedMessage)"
        }.joined(separator: "\n")
        
        
        // Now `logMessages` contains your formatted log entries
        // Next, you would write this string to a file to share
        if let documentDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let logFileUrl = documentDirectory.appendingPathComponent("appLogs.txt")
            try? logMessages.write(to: logFileUrl, atomically: true, encoding: .utf8)
            
            // Share the file using UIActivityViewController
            // Ensure this is called on the main thread, e.g., within a UIViewController
            DispatchQueue.main.async {
                let activityViewController = UIActivityViewController(activityItems: [logFileUrl], applicationActivities: nil)
                self.present(activityViewController, animated: true, completion: nil)
            }
        } else {
            print("nope")
        }

        
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.allowsBackgroundLocationUpdates = true

        locationManager.requestAlwaysAuthorization()
        
        if CLLocationManager.authorizationStatus() == .authorizedAlways || CLLocationManager.authorizationStatus() == .authorizedWhenInUse {
            locationManager.startUpdatingLocation()
        }
        
        webServer.delegate = self
        webServer.addHandler(forMethod: "GET", path: "/readings", request: GCDWebServerRequest.self, processBlock: { [weak self] request in
            guard let self = self else {
                fatalError()
            }

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            
            let pastFiveMinsOBDData = readingsService.getPast5MinutesOfReadings()
            
            guard let jsonData = try? encoder.encode(pastFiveMinsOBDData) else {
                return GCDWebServerDataResponse(jsonObject: ["error": "could not encode codable obd data"])!
            }
            
            guard let obdDataObject = try? JSONSerialization.jsonObject(with: jsonData, options: []) as? [[String: Any]] else {
                return GCDWebServerDataResponse(jsonObject: ["error": "could not encode obd data object"])!
            }

            return GCDWebServerDataResponse(jsonObject: [
                "obd_data": obdDataObject as Any,
                "device_state": self.viewModel.deviceState as Any,
                "protocol_version": self.viewModel.protocolVersion as Any,
                "vin": self.viewModel.vin as Any
            ])
        })

        // expose web server for requests
        startWebServer()

        // load saved defaults
        viewModel.tankCapacity = savedTankCapacity
//        viewModel.baseDistance = savedBaseDistance
        bind(viewModel)

        tankCapacityField.text = String(savedTankCapacity)
//        odometerTextField.text = String(savedBaseDistance)

        // set up background audio playback
        setupAudioPlayer()
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleAudioSessionInterruption),
                                               name: AVAudioSession.interruptionNotification,
                                               object: AVAudioSession.sharedInstance())
        
        NotificationCenter.default.addObserver(self, selector: #selector(onAdapterChangedState), name: NSNotification.Name(rawValue: LTOBD2AdapterDidUpdateState), object: nil)

        // connect to adapter automatically only on first launch.
        connectToAdapter()

//        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        
        // get keyboard show/hide notifications
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow), name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide), name: UIResponder.keyboardWillHideNotification, object: nil)
        
        miniserverTimer = Timer.scheduledTimer(timeInterval: 10.0, target: self, selector: #selector(pollMiniserver), userInfo: nil, repeats: true)
        pollMiniserver()
    }
    
//    @objc func applicationDidBecomeActive() {
//        // gets called on first open as well, this is where the first connection happens
//        connectToAdapter()
//    }
    
    @objc func keyboardWillShow(notification: NSNotification) {
        if let keyboardSize = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue {
            UIView.animate(withDuration: 0.3) {
                if self.view.transform.ty == 0 {
                    self.view.transform.ty -= keyboardSize.height * 0.3
                }
            }
        }
    }
    
    @objc func keyboardWillHide(notification: NSNotification) {
        UIView.animate(withDuration: 0.3) {
            if self.view.transform.ty != 0 {
                self.view.transform.ty = 0
            }
        }
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
    
    @objc func pollMiniserver() {
        if !LoxoneService.shared.isFetching {
            LoxoneService.shared.fetchSpareTankValue()
        }
    }
    
    // updates sensor data in a loop
    func updateSensorData() {
        let rpm = LTOBD2PID_ENGINE_RPM_0C.forMode1()
        let fuelRate = LTOBD2PID_ENGINE_FUEL_RATE_5E.forMode1()
        let coolantTemp = LTOBD2PID_COOLANT_TEMP_05.forMode1()
        let fuelLevel = LTOBD2PID_FUEL_TANK_LEVEL_2F.forMode1()
        let engineLoad = LTOBD2PID_ENGINE_LOAD_04.forMode1()
        let odometer = LTOBD2PID_ODOMETER_A6.forMode1()

        guard let obd2Adapter else {
            fatalError()
        }
        
        let commands = [rpm, odometer, fuelRate, coolantTemp, fuelLevel, engineLoad]
        obd2Adapter.transmitMultipleCommands(commands, completionHandler: { [weak self] commands in
            DispatchQueue.main.async {
                let rpm = Int(rpm.formattedResponse.replacingOccurrences(of: "\u{202F}rpm", with: ""))
                // let distanceReading = Double(distanceTraveled.formattedResponse.replacingOccurrences(of: "\u{202F}km", with: ""))
                let odometerReading = Double(odometer.formattedResponse.replacingOccurrences(of: "\u{202F}km", with: ""))
                let fuelRate = Double(fuelRate.formattedResponse.replacingOccurrences(of: "\u{202F}L/h", with: ""))
                let waterTemp = Int(coolantTemp.formattedResponse.replacingOccurrences(of: "\u{202F}°C", with: ""))
                let fuelLevel = Double(fuelLevel.formattedResponse.replacingOccurrences(of: "\u{202F}%", with: ""))
                let engineLoad = Double(engineLoad.formattedResponse.replacingOccurrences(of: "\u{202F}%", with: ""))
                
                let obdData = OBDDataPoint(
                    latitude: self?.viewModel.lastKnownLatitude,
                    longitude: self?.viewModel.lastKnownLongitude,
                    elevation: self?.viewModel.lastKnownElevation,
                    time: Date(),
                    rpm: rpm,
//                    distanceReading: odometer,
                    fuelRate: fuelRate,
                    waterTemp: waterTemp,
                    fuelLevel: fuelLevel,
                    engineLoad: engineLoad,
                    odometerReading: odometerReading,
//                    baseDistance: self?.viewModel.baseDistance,
                    tankCapacity: self?.viewModel.tankCapacity
                )
                
                self?.viewModel.obdData = obdData
                
                if let obdData {
                    DispatchQueue.main.async {
                        self?.readingsService.addReading(obdData)
                    }
                }
                
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
    
    func setNewMiniserverURL(_ url: String) {
        LoxoneService.shared.miniserverURL = url
    }
    
    func bind(_ viewModel: ViewModel) {
        serverStatusLabel.text = viewModel.isServerRunning ? "Running" : "Not Running"
        serverAddressLabel.text = webServer.serverURL?.absoluteString ?? "<unavailable>"
        deviceStatusLabel.text = viewModel.deviceState

        vinLabel.text = viewModel.vin
        obdProtocolLabel.text = viewModel.protocolVersion
        
        if let obdData = viewModel.obdData {
            rpmLabel.text = obdData.rpm == nil ? "<unavailable>" : String(obdData.rpm!) + " rpm"
            odometerLabel.text = obdData.odometerReading == nil ? "<unavailable>" : String(obdData.odometerReading!) + " km"
            fuelRateLabel.text = obdData.fuelRate == nil ? "<unavailable>" : String(obdData.fuelRate!) + " L/h"
            waterTempLabel.text = obdData.waterTemp == nil ? "<unavailable>" : String(obdData.waterTemp!) + " °C"
            fuelInTankLabel.text = obdData.fuelInTank == nil ? "<unavailable>" : String(obdData.fuelInTank!) + " L"
            engineLoadLabel.text = obdData.engineLoad == nil ? "<unavailable>" : String(obdData.engineLoad!) + "%"
        } else {
            rpmLabel.text = "<unavailable>"
            odometerLabel.text = "<unavailable>"
            fuelRateLabel.text = "<unavailable>"
            waterTempLabel.text = "<unavailable>"
            fuelInTankLabel.text = "<unavailable>"
            engineLoadLabel.text = "<unavailable>"
        }
    }
    
    func saveNewOdometerReading(_ reading: String) {
        guard let readingNumber = Double(reading) else {
            // show error alert
            let alert = UIAlertController(title: "Error", message: "Invalid Odometer Reading -- please only enter numbers", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
            present(alert, animated: true)
            return
        }
        
//        let obdDistance = viewModel.obdData?.distanceReading ?? 0
//        let newBaseDistance = readingNumber - obdDistance
//        viewModel.baseDistance = newBaseDistance
//        savedBaseDistance = newBaseDistance
    }
    
    @IBAction func changeBaseOdometerTapped() {
        if odometerTextField.isHidden {
            odometerTextField.isHidden = false
            odometerLabel.isHidden = true
//            odometerTextField.text = String(viewModel.obdData?.distanceReading ?? savedBaseDistance)
            odometerTextField.selectAll(nil)
            odometerTextField.becomeFirstResponder()
            odometerActionButton.setTitle("Save", for: .normal)
            odometerCancelButton.isHidden = false
        } else {
            odometerLabel.isHidden = false
            odometerTextField.isHidden = true
            odometerActionButton.setTitle("Change", for: .normal)
            odometerCancelButton.isHidden = true
            saveNewOdometerReading(odometerTextField.text ?? "")
            odometerTextField.endEditing(true)
        }
    }
    
    @IBAction func cancelOdometerChangesTapped() {
        if odometerTextField.isHidden {
            return
        }
        
        odometerLabel.isHidden = false
        odometerTextField.isHidden = true
        odometerActionButton.setTitle("Change", for: .normal)
        odometerCancelButton.isHidden = true
        odometerTextField.endEditing(true)
    }
    
    @IBAction func changeMiniserverTapped() {
        if miniserverTextField.isHidden {
            miniserverTextField.isHidden = false
            spareTankLabel.isHidden = true
//            spareTankLabel.text = String(viewModel.obdData?.distanceReading ?? savedBaseDistance)
            miniserverTextField.selectAll(nil)
            miniserverTextField.becomeFirstResponder()
            miniserverActionButton.setTitle("Save", for: .normal)
            miniserverCancelButton.isHidden = false
        } else {
            spareTankLabel.isHidden = false
            miniserverTextField.isHidden = true
            miniserverActionButton.setTitle("Change", for: .normal)
            miniserverCancelButton.isHidden = true
            setNewMiniserverURL(miniserverTextField.text ?? "")
            miniserverTextField.endEditing(true)
        }
    }
    
    @IBAction func cancelMiniserverChangesTapped() {
        if miniserverTextField.isHidden {
            return
        }
        
        spareTankLabel.isHidden = false
        miniserverTextField.isHidden = true
        miniserverActionButton.setTitle("Change", for: .normal)
        miniserverCancelButton.isHidden = true
        miniserverTextField.endEditing(true)
    }
    
    @IBAction func reconnectTapped() {
        self.connectToAdapter()
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
            savedTankCapacity = Double(textField.text ?? "") ?? savedTankCapacity
            viewModel.tankCapacity = savedTankCapacity
            textField.text = String(savedTankCapacity)
            textField.endEditing(true)
        }
        
        return true
    }
}

extension ViewController: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            return
        }
        
        viewModel.lastKnownLatitude = location.coordinate.latitude
        viewModel.lastKnownLongitude = location.coordinate.longitude
        viewModel.lastKnownElevation = location.altitude
//        print("new location:", location.coordinate)
    }
    
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        switch status {
        case .restricted, .denied:
            // Handle restriction or denial
            break
        case .authorizedWhenInUse, .authorizedAlways:
            // Location permissions are granted. Start updating locations
            locationManager.startUpdatingLocation()
        default:
            break
        }
    }

}
