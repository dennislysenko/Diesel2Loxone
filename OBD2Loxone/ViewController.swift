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
    
    var tankInfo: TankInfo?
}

let isoDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXX" // ISO 8601 with timezone
    formatter.timeZone = TimeZone.current
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
}()

// Extend JSONEncoder to include the custom date encoding strategy
extension JSONEncoder {
    static func isoDateEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .formatted(isoDateFormatter)
        return encoder
    }
}


struct TankInfo: Codable {
    var mainTankLevel: Double?
    var auxTankLevel: Double?
    var mainTankLevelUnit: String?
    var auxTankLevelUnit: String?
    var mainTankPrice: Double?
    var mainTankPriceUnit: String?
    var odometer: Double?
}

struct TankDisplayInfo: Codable {
    var mainTankLevelLiters: Double?
    var auxTankLevelLiters: Double?
    var pricePerLiter: Double?
    var odometer: Double?
    
    init(from tankInfo: TankInfo) {
        if let mainTankLevel = tankInfo.mainTankLevel {
            if tankInfo.mainTankLevelUnit == "L" {
                mainTankLevelLiters = mainTankLevel
            } else {
                // gallons to liters
                mainTankLevelLiters = mainTankLevel * 3.785
            }
        }
        
        if let auxTankLevel = tankInfo.auxTankLevel {
            if tankInfo.auxTankLevelUnit == "L" {
                auxTankLevelLiters = auxTankLevel
            } else {
                // gallon to liters
                auxTankLevelLiters = auxTankLevel * 3.785
            }
        }

        if let price = tankInfo.mainTankPrice {
            if tankInfo.mainTankPriceUnit == "/L" {
                pricePerLiter = price
            } else {
                // $/gal to $/L
                pricePerLiter = price / 3.785
            }
        }

        odometer = tankInfo.odometer
    }
}

struct DisplayEntry: Codable {
    let tankInfo: TankDisplayInfo
    let id: Int
    let time: Date
    
    init(from entry: EntriesService.Entry) {
        tankInfo = TankDisplayInfo(from: entry.tankInfo)
        id = entry.id
        time = entry.time
    }
}

struct HasNewReadingResponse: Codable {
    let status: Int
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
    
    @UserDefault(key: "mainTankLevel", defaultValue: 10)
    var savedMainTankLevel: Double
    
    @UserDefault(key: "auxTankLevel", defaultValue: 10)
    var savedAuxTankLevel: Double
    
    @UserDefault(key: "mainTankLevelUnit", defaultValue: "gal")
    var savedMainLevelUnit: String
    
    @UserDefault(key: "auxTankLevelUnit", defaultValue: "gal")
    var savedAuxLevelUnit: String
    
    @UserDefault(key: "mainTankPrice", defaultValue: 5.50)
    var savedMainPrice: Double
    
    @UserDefault(key: "mainTankPriceUnit", defaultValue: "/gal")
    var savedMainPriceUnit: String
    
    @UserDefault(key: "odometer", defaultValue: 0)
    var savedOdometerReading: Double
    
    @UserDefault(key: "hasNewReading", defaultValue: false)
    var hasNewReading: Bool
    
//    let locationManager = CLLocationManager()
    
    let readingsService = ReadingsService.shared
    
    @IBOutlet var editableFields: [UIControl]!
    
    @IBOutlet weak var editButton: UIButton!
    @IBOutlet weak var saveButton: UIButton!
    
    @IBOutlet weak var lastUpdatedLabel: UILabel!
    @IBOutlet weak var loxoneAckLabel: UILabel!
    
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
    
    @IBOutlet weak var mainTankLevelField: UITextField!
    @IBOutlet weak var auxTankLevelField: UITextField!
    @IBOutlet weak var mainLevelUnitControl: UISegmentedControl!
    @IBOutlet weak var auxLevelUnitControl: UISegmentedControl!
    
    @IBOutlet weak var mainPriceField: UITextField!
    @IBOutlet weak var auxPriceField: UITextField!
    // price units
    @IBOutlet weak var mainPriceUnitControl: UISegmentedControl!
    @IBOutlet weak var auxPriceUnitControl: UISegmentedControl!
    
    var miniserverTimer: Timer?
    
    let dynamicBackgroundColor = UIColor { traitCollection in
        return traitCollection.userInterfaceStyle == .dark ? .black : .white
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        
//        locationManager.delegate = self
//        locationManager.desiredAccuracy = kCLLocationAccuracyBest
//        locationManager.pausesLocationUpdatesAutomatically = false
//        locationManager.allowsBackgroundLocationUpdates = true
//
//        locationManager.requestAlwaysAuthorization()
//        
//        if CLLocationManager.authorizationStatus() == .authorizedAlways || CLLocationManager.authorizationStatus() == .authorizedWhenInUse {
//            locationManager.startUpdatingLocation()
//        }
        
        webServer.delegate = self
        webServer.addHandler(forMethod: "GET", path: "/readings", request: GCDWebServerRequest.self, processBlock: { [weak self] request in
            guard let self = self else {
                fatalError()
            }

            let encoder = JSONEncoder.isoDateEncoder()
            
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
        
        
        webServer.addHandler(forMethod: "GET", path: "/levels", request: GCDWebServerRequest.self, processBlock: { [weak self] request in
            guard let currentEntry = EntriesService.shared.entries.first else {
                return GCDWebServerDataResponse(jsonObject: ["error": "no entries"])!
            }
            
            let encoder = JSONEncoder.isoDateEncoder()
            guard let jsonData = try? encoder.encode(DisplayEntry(from: currentEntry)) else {
                return GCDWebServerDataResponse(jsonObject: ["error": "could not encode codable entry"])!
            }

            return GCDWebServerDataResponse(data: jsonData, contentType: "application/json")
        })
        
        webServer.addHandler(forMethod: "GET", path: "/has_new_reading", request: GCDWebServerRequest.self, processBlock: { [weak self] request in
            guard let self = self else {
                fatalError()
            }
            
            let hasNewReadingResponse = HasNewReadingResponse(status: hasNewReading ? 1 : 0)
            
            let encoder = JSONEncoder()
            guard let jsonData = try? encoder.encode(hasNewReadingResponse) else {
                return GCDWebServerDataResponse(jsonObject: ["error": "could not encode codable entry"])!
            }
            
            return GCDWebServerDataResponse(data: jsonData, contentType: "application/json")
        })
        
        webServer.addHandler(forMethod: "GET", path: "/consume_new_reading", request: GCDWebServerRequest.self, processBlock: { [weak self] request in
            guard let self = self else {
                fatalError()
            }
            
            hasNewReading = false
            DispatchQueue.main.async {
                self.loxoneAckLabel.text = "No New Reading"
            }
            
            return GCDWebServerResponse(statusCode: 200)
        })
        
        

        // expose web server for requests
        startWebServer()

        // load saved defaults
        viewModel.tankCapacity = savedTankCapacity
        bind(viewModel)

        odometerTextField.text = String(savedOdometerReading)
        mainTankLevelField.text = String(savedMainTankLevel)
        auxTankLevelField.text = String(savedAuxTankLevel)
        mainPriceField.text = String(savedMainPrice)
        mainPriceUnitControl.selectedSegmentIndex = savedMainPriceUnit == "/gal" ? 0 : 1
        mainLevelUnitControl.selectedSegmentIndex = savedMainLevelUnit == "gal" ? 0 : 1
        auxLevelUnitControl.selectedSegmentIndex = savedAuxLevelUnit == "gal" ? 0 : 1
        
        viewModel.tankInfo = TankInfo(
            mainTankLevel: savedMainTankLevel,
            auxTankLevel: savedAuxTankLevel,
            mainTankLevelUnit: savedMainLevelUnit,
            auxTankLevelUnit: savedAuxLevelUnit,
            mainTankPrice: savedMainPrice,
            mainTankPriceUnit: savedMainPriceUnit,
            odometer: savedOdometerReading
        )
        
        let df = DateFormatter()
        df.dateFormat = "d MMM, HH:mm"
        if let lastUpdatedDate = EntriesService.shared.entries.first?.time {
            lastUpdatedLabel.text = "Last updated: \(df.string(from: lastUpdatedDate))"
        }
        
        loxoneAckLabel.text = hasNewReading ? "Has New Reading" : "No New Reading"
        
        editableFields.forEach { 
            $0.isEnabled = false
            $0.backgroundColor = .clear
        }
        saveButton.isHidden = true
        
        

        // set up background audio playback
        setupAudioPlayer()
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleAudioSessionInterruption),
                                               name: AVAudioSession.interruptionNotification,
                                               object: AVAudioSession.sharedInstance())
        
        NotificationCenter.default.addObserver(self, selector: #selector(onAdapterChangedState), name: NSNotification.Name(rawValue: LTOBD2AdapterDidUpdateState), object: nil)

        // connect to adapter automatically only on first launch.
//        connectToAdapter()

//        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        
        // get keyboard show/hide notifications
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow), name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide), name: UIResponder.keyboardWillHideNotification, object: nil)
    }
    
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
//            setNewMiniserverURL(miniserverTextField.text ?? "")
            miniserverTextField.endEditing(true)
        }
    }
    
    @IBAction func editTapped() {
        editableFields.forEach({ $0.isEnabled = true; $0.backgroundColor = dynamicBackgroundColor })
        saveButton.isHidden = false
        editButton.isHidden = true
    }
    
    @IBAction func saveTapped() {
        editableFields.forEach({ $0.isEnabled = false; $0.backgroundColor = .clear })
        saveButton.isHidden = true
        editButton.isHidden = false
    
        savedMainTankLevel = Double(mainTankLevelField.text ?? "") ?? savedMainTankLevel
        viewModel.tankInfo!.mainTankLevel = savedMainTankLevel
        mainTankLevelField.text = String(savedMainTankLevel)

        savedAuxTankLevel = Double(auxTankLevelField.text ?? "") ?? savedAuxTankLevel
        viewModel.tankInfo!.auxTankLevel = savedAuxTankLevel
        auxTankLevelField.text = String(savedAuxTankLevel)

        savedMainPrice = Double(mainPriceField.text ?? "") ?? savedMainPrice
        viewModel.tankInfo!.mainTankPrice = savedMainPrice
        mainPriceField.text = String(savedMainPrice)

        savedMainPriceUnit = mainPriceUnitControl.selectedSegmentIndex == 0 ? "/gal" : "/L"
        viewModel.tankInfo?.mainTankPriceUnit = savedMainPriceUnit
        mainPriceUnitControl.selectedSegmentIndex = savedMainPriceUnit == "/gal" ? 0 : 1
        
        savedMainLevelUnit = mainLevelUnitControl.selectedSegmentIndex == 0 ? "gal" : "L"
        viewModel.tankInfo?.mainTankLevelUnit = savedMainLevelUnit
        mainLevelUnitControl.selectedSegmentIndex = savedMainLevelUnit == "gal" ? 0 : 1
        
        savedAuxLevelUnit = auxLevelUnitControl.selectedSegmentIndex == 0 ? "gal" : "L"
        viewModel.tankInfo?.auxTankLevelUnit = savedAuxLevelUnit
        auxLevelUnitControl.selectedSegmentIndex = savedAuxLevelUnit == "gal" ? 0 : 1
        
        savedOdometerReading = Double(odometerTextField.text ?? "") ?? savedOdometerReading
        viewModel.tankInfo?.odometer = savedOdometerReading
        odometerTextField.text = String(savedOdometerReading)
        
        EntriesService.shared.log(tankInfo: viewModel.tankInfo!)
        hasNewReading = true
        
        loxoneAckLabel.text = "Has New Reading"
        
        let df = DateFormatter()
        df.dateFormat = "d MMM, HH:mm"
        if let lastUpdatedDate = EntriesService.shared.entries.first?.time {
            lastUpdatedLabel.text = "Last updated: \(df.string(from: lastUpdatedDate))"
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
    
    @IBAction func getEntryLogTapped() {
        let entries = EntriesService.shared.entries
        do {
            let encoder = JSONEncoder.isoDateEncoder()
            let jsonData = try encoder.encode(entries)
            let jsonString = String(data: jsonData, encoding: .utf8)
            
            
            print(jsonString ?? "no log")
            
            
            let tempFile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("entries.json")
            try jsonString?.write(to: tempFile, atomically: true, encoding: .utf8)
            let vc = UIActivityViewController(activityItems: [tempFile], applicationActivities: nil)
            present(vc, animated: true)
        } catch let error {
            print(error)
            let alert = UIAlertController(title: "Error", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
            present(alert, animated: true)
        }
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
    
    func textFieldDidEndEditing(_ textField: UITextField) {
//        if textField == tankCapacityField {
//            savedTankCapacity = Double(textField.text ?? "") ?? savedTankCapacity
//            viewModel.tankCapacity = savedTankCapacity
//            textField.text = String(savedTankCapacity)
//            textField.endEditing(true)
//        } else if textField == mainTankLevelField {
//            savedMainTankLevel = Double(textField.text ?? "") ?? savedMainTankLevel
//            viewModel.tankInfo!.mainTankLevel = savedMainTankLevel
//            EntriesService.shared.log(tankInfo: viewModel.tankInfo!)
//            textField.text = String(savedMainTankLevel)
//            textField.endEditing(true)
//        } else if textField == auxTankLevelField {
//            savedAuxTankLevel = Double(textField.text ?? "") ?? savedAuxTankLevel
//            viewModel.tankInfo!.auxTankLevel = savedAuxTankLevel
//            EntriesService.shared.log(tankInfo: viewModel.tankInfo!)
//            textField.text = String(savedAuxTankLevel)
//            textField.endEditing(true)
//        } else if textField == priceField {
//            savedPrice = Double(textField.text ?? "") ?? savedPrice
//            viewModel.tankInfo!.price = savedPrice
//            EntriesService.shared.log(tankInfo: viewModel.tankInfo!)
//            textField.text = String(savedPrice)
//            textField.endEditing(true)
//        }
        
        textField.endEditing(true)
    }
}

//extension ViewController: CLLocationManagerDelegate {
//    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
//        guard let location = locations.last else {
//            return
//        }
//        
//        viewModel.lastKnownLatitude = location.coordinate.latitude
//        viewModel.lastKnownLongitude = location.coordinate.longitude
//        viewModel.lastKnownElevation = location.altitude
////        print("new location:", location.coordinate)
//    }
//    
//    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
//        switch status {
//        case .restricted, .denied:
//            // Handle restriction or denial
//            break
//        case .authorizedWhenInUse, .authorizedAlways:
//            // Location permissions are granted. Start updating locations
//            locationManager.startUpdatingLocation()
//        default:
//            break
//        }
//    }
//
//}
