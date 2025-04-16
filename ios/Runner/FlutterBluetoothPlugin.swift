import Flutter
import UIKit
import CoreBluetooth
import ExternalAccessory

public class FlutterBluetoothPlugin: NSObject, FlutterPlugin, CBCentralManagerDelegate, CBPeripheralDelegate, EAAccessoryDelegate, FlutterStreamHandler {
    private let TAG = "FlutterBluetoothPlugin"
    private let methodChannel: FlutterMethodChannel
    private let discoveredDevicesChannel: FlutterEventChannel
    private let receivedDataChannel: FlutterEventChannel
    private let pairingStateChannel: FlutterEventChannel
    private let pairedDevicesChannel: FlutterEventChannel

    private var centralManager: CBCentralManager?
    private var connectedPeripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?

    private var accessoryManager: EAAccessoryManager
    private var connectedAccessory: EAAccessory?
    private var session: EASession?

    private var discoveredDevicesSink: FlutterEventSink?
    private var receivedDataSink: FlutterEventSink?
    private var pairingStateSink: FlutterEventSink?
    private var pairedDevicesSink: FlutterEventSink?

    private var isBleScanning = false
    private var scanTimeoutTimer: Timer?

    private let sppProtocolString = "com.apple.spp" // Replace with actual protocol string for your device

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = FlutterBluetoothPlugin(registrar: registrar)
        registrar.addMethodCallDelegate(instance, channel: instance.methodChannel)
    }

    init(registrar: FlutterPluginRegistrar) {
        methodChannel = FlutterMethodChannel(name: "com.example/bluetooth", binaryMessenger: registrar.messenger())
        discoveredDevicesChannel = FlutterEventChannel(name: "com.example/bluetooth_discovered_devices", binaryMessenger: registrar.messenger())
        receivedDataChannel = FlutterEventChannel(name: "com.example/bluetooth_received_data", binaryMessenger: registrar.messenger())
        pairingStateChannel = FlutterEventChannel(name: "com.example/bluetooth_pairing_state", binaryMessenger: registrar.messenger())
        pairedDevicesChannel = FlutterEventChannel(name: "com.example/bluetooth_paired_devices", binaryMessenger: registrar.messenger())

        accessoryManager = EAAccessoryManager.shared()
        super.init()

        centralManager = CBCentralManager(delegate: self, queue: .main)
        discoveredDevicesChannel.setStreamHandler(self)
        receivedDataChannel.setStreamHandler(self)
        pairingStateChannel.setStreamHandler(self)
        pairedDevicesChannel.setStreamHandler(self)

        methodChannel.setMethodCallHandler(handle)

        // Register for accessory connection notifications
        NotificationCenter.default.addObserver(self, selector: #selector(accessoryDidConnect), name: EAAccessoryManager.didConnectAccessoryNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(accessoryDidDisconnect), name: EAAccessoryManager.didDisconnectAccessoryNotification, object: nil)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "startScanning":
            guard let args = call.arguments as? [String: Any],
                  let isBle = args["isBle"] as? Bool,
                  let timeout = args["timeout"] as? Int else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "Invalid arguments", details: nil))
                return
            }
            if centralManager?.state != .poweredOn && isBle {
                result(FlutterError(code: "BLUETOOTH_NOT_AVAILABLE", message: "Bluetooth is not available or not enabled", details: nil))
                return
            }
            if isBle {
                startBleScanning(timeout: timeout)
            } else {
                startClassicScanning(timeout: timeout)
            }
            result(nil)

        case "stopScanning":
            let isBle = (call.arguments as? [String: Any])?["isBle"] as? Bool ?? false
            if isBle {
                stopBleScanning()
            } else {
                stopClassicScanning()
            }
            result(nil)

        case "getPairedDevices":
            getPairedDevices(result: result)

        case "connectToDevice":
            guard let args = call.arguments as? [String: Any],
                  let address = args["address"] as? String,
                  let isBle = args["isBle"] as? Bool else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "Device address is required", details: nil))
                return
            }
            if isBle {
                connectToBleDevice(address: address, result: result)
            } else {
                connectToClassicDevice(address: address, result: result)
            }

        case "disconnect":
            let isBle = (call.arguments as? [String: Any])?["isBle"] as? Bool ?? false
            if isBle {
                disconnectBle()
            } else {
                disconnectClassic()
            }
            result(nil)

        case "sendData":
            guard let args = call.arguments as? [String: Any],
                  let data = args["data"] as? String,
                  let address = args["address"] as? String,
                  let isBle = args["isBle"] as? Bool else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "Data and address are required", details: nil))
                return
            }
            if isBle {
                sendBleData(data: data, result: result)
            } else {
                sendReceipt(address: address, text: data, result: result)
            }

        case "checkStatus":
            let isBle = (call.arguments as? [String: Any])?["isBle"] as? Bool ?? false
            if isBle {
                checkBleStatus(result: result)
            } else {
                checkClassicStatus(result: result)
            }

        case "pairDevice":
            guard let args = call.arguments as? [String: Any],
                  let address = args["address"] as? String else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "Device address is required", details: nil))
                return
            }
            pairDevice(address: address, result: result)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - FlutterStreamHandler
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        switch arguments as? String {
        case "com.example/bluetooth_discovered_devices":
            discoveredDevicesSink = events
        case "com.example/bluetooth_received_data":
            receivedDataSink = events
        case "com.example/bluetooth_pairing_state":
            pairingStateSink = events
        case "com.example/bluetooth_paired_devices":
            pairedDevicesSink = events
            emitPairedDevices()
        default:
            return FlutterError(code: "INVALID_CHANNEL", message: "Unknown channel", details: nil)
        }
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        switch arguments as? String {
        case "com.example/bluetooth_discovered_devices":
            discoveredDevicesSink = nil
        case "com.example/bluetooth_received_data":
            receivedDataSink = nil
        case "com.example/bluetooth_pairing_state":
            pairingStateSink = nil
        case "com.example/bluetooth_paired_devices":
            pairedDevicesSink = nil
        default:
            return FlutterError(code: "INVALID_CHANNEL", message: "Unknown channel", details: nil)
        }
        return nil
    }

    // MARK: - CBCentralManagerDelegate
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            print("\(TAG): Bluetooth is powered on")
        case .poweredOff:
            print("\(TAG): Bluetooth is powered off")
        case .unauthorized:
            print("\(TAG): Bluetooth unauthorized")
        default:
            print("\(TAG): Bluetooth state unknown: \(central.state)")
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? "Unknown"
        let address = peripheral.identifier.uuidString
        print("\(TAG): Discovered BLE device: \(name) (\(address))")
        discoveredDevicesSink?(["name": name, "address": address, "uuids": [], "type": "BLE", "isBle": true])
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("\(TAG): Connected to BLE peripheral: \(peripheral.name ?? "Unknown")")
        connectedPeripheral = peripheral
        peripheral.delegate = self
        peripheral.discoverServices(nil)
        receivedDataSink?("BLE Connected")
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        print("\(TAG): Disconnected from BLE peripheral: \(peripheral.name ?? "Unknown")")
        connectedPeripheral = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        receivedDataSink?("BLE Disconnected")
    }

    // MARK: - CBPeripheralDelegate
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            print("\(TAG): Service discovery failed: \(error.localizedDescription)")
            receivedDataSink?(FlutterError(code: "BLE_SERVICE_ERROR", message: error.localizedDescription, details: nil))
            return
        }
        peripheral.services?.forEach { service in
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            print("\(TAG): Characteristic discovery failed: \(error.localizedDescription)")
            receivedDataSink?(FlutterError(code: "BLE_CHARACTERISTIC_ERROR", message: error.localizedDescription, details: nil))
            return
        }
        service.characteristics?.forEach { characteristic in
            if characteristic.properties.contains(.write) || characteristic.properties.contains(.writeWithoutResponse) {
                writeCharacteristic = characteristic
            }
            if characteristic.properties.contains(.notify) {
                notifyCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("\(TAG): Characteristic update failed: \(error.localizedDescription)")
            receivedDataSink?(FlutterError(code: "BLE_READ_ERROR", message: error.localizedDescription, details: nil))
            return
        }
        if let value = characteristic.value, let data = String(data: value, encoding: .utf8) {
            print("\(TAG): Received BLE data: \(data)")
            receivedDataSink?(data)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("\(TAG): Characteristic write failed: \(error.localizedDescription)")
            receivedDataSink?(FlutterError(code: "BLE_WRITE_ERROR", message: error.localizedDescription, details: nil))
        } else {
            print("\(TAG): Characteristic write successful")
        }
    }

    // MARK: - EAAccessoryDelegate
    @objc func accessoryDidConnect(notification: Notification) {
        guard let accessory = notification.userInfo?[EAAccessoryManagerConnectedAccessoryKey] as? EAAccessory else { return }
        print("\(TAG): Classic accessory connected: \(accessory.name ?? "Unknown")")
        pairingStateSink?(["address": accessory.serialNumber, "bondState": 12]) // BOND_BONDED
        emitPairedDevices()
    }

    @objc func accessoryDidDisconnect(notification: Notification) {
        guard let accessory = notification.userInfo?[EAAccessoryManagerDisconnectedAccessoryKey] as? EAAccessory else { return }
        print("\(TAG): Classic accessory disconnected: \(accessory.name ?? "Unknown")")
        pairingStateSink?(["address": accessory.serialNumber, "bondState": 10]) // BOND_NONE
        if connectedAccessory?.serialNumber == accessory.serialNumber {
            disconnectClassic()
        }
    }

    // MARK: - Bluetooth Classic Methods
    private func startClassicScanning(timeout: Int) {
        print("\(TAG): Starting Bluetooth Classic scanning")
        accessoryManager.showBluetoothAccessoryPicker(withNameFilter: nil) { error in
            if let error = error {
                print("\(TAG): Classic scan failed: \(error.localizedDescription)")
                self.discoveredDevicesSink?(FlutterError(code: "CLASSIC_SCAN_ERROR", message: error.localizedDescription, details: nil))
            }
        }

        // Simulate discovered devices from connected accessories
        let accessories = accessoryManager.connectedAccessories
        accessories.forEach { accessory in
            let name = accessory.name ?? "Unknown"
            let address = accessory.serialNumber
            print("\(TAG): Found classic device: \(name) (\(address))")
            discoveredDevicesSink?(["name": name, "address": address, "uuids": [self.sppProtocolString], "type": "Classic", "isBle": false])
        }

        if timeout > 0 {
            scanTimeoutTimer?.invalidate()
            scanTimeoutTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(timeout), repeats: false) { _ in
                self.stopClassicScanning()
                self.discoveredDevicesSink?(["event": "timeout", "message": "Classic discovery stopped after \(timeout) seconds"])
            }
        }
    }

    private func stopClassicScanning() {
        print("\(TAG): Stopping Bluetooth Classic scanning")
        scanTimeoutTimer?.invalidate()
        scanTimeoutTimer = nil
    }

    private func connectToClassicDevice(address: String, result: @escaping FlutterResult) {
        let accessories = accessoryManager.connectedAccessories
        guard let accessory = accessories.first(where: { $0.serialNumber == address }) else {
            print("\(TAG): Classic device not found: \(address)")
            result(FlutterError(code: "DEVICE_NOT_FOUND", message: "Device not found", details: nil))
            return
        }

        disconnectClassic()

        connectedAccessory = accessory
        session = EASession(accessory: accessory, forProtocol: sppProtocolString)

        guard let session = session else {
            print("\(TAG): Failed to create session for \(address)")
            result(FlutterError(code: "SESSION_ERROR", message: "Failed to create session", details: nil))
            return
        }

        session.inputStream?.delegate = self
        session.inputStream?.schedule(in: .main, forMode: .default)
        session.inputStream?.open()

        session.outputStream?.delegate = self
        session.outputStream?.schedule(in: .main, forMode: .default)
        session.outputStream?.open()

        print("\(TAG): Connected to classic device: \(address)")
        startClassicReading()
        result(nil)
    }

    private func disconnectClassic() {
        print("\(TAG): Disconnecting Bluetooth Classic")
        session?.inputStream?.close()
        session?.inputStream?.remove(from: .main, forMode: .default)
        session?.inputStream?.delegate = nil

        session?.outputStream?.close()
        session?.outputStream?.remove(from: .main, forMode: .default)
        session?.outputStream?.delegate = nil

        session = nil
        connectedAccessory = nil
        print("\(TAG): Classic disconnected")
    }

    private func sendReceipt(address: String, text: String, result: @escaping FlutterResult) {
        guard let outputStream = session?.outputStream, outputStream.hasSpaceAvailable else {
            print("\(TAG): Classic not connected or output stream unavailable")
            result(FlutterError(code: "NOT_CONNECTED", message: "Not connected to device", details: nil))
            return
        }

        // ESC/POS commands
        let initialize = Data([0x1B, 0x40])
        let centerAlign = Data([0x1B, 0x61, 0x01])
        let printText = text.data(using: .ascii) ?? Data()
        let lineFeed = Data([0x0A])
        let cutPaper = Data([0x1D, 0x56, 0x00])

        let data = initialize + centerAlign + printText + lineFeed + cutPaper

        let bytesWritten = data.withUnsafeBytes { buffer in
            outputStream.write(buffer.baseAddress!, maxLength: buffer.count)
        }

        if bytesWritten > 0 {
            print("\(TAG): Sent ESC/POS data: \(text)")
            result(nil)
        } else {
            print("\(TAG): Failed to send classic data")
            result(FlutterError(code: "SEND_ERROR", message: "Failed to send data", details: nil))
        }
    }

    private func startClassicReading() {
        guard let inputStream = session?.inputStream else { return }
        DispatchQueue.global(qos: .background).async {
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
            defer { buffer.deallocate() }

            while inputStream.hasBytesAvailable {
                let bytesRead = inputStream.read(buffer, maxLength: 1024)
                if bytesRead > 0 {
                    let data = Data(bytes: buffer, count: bytesRead)
                    if let string = String(data: data, encoding: .utf8) {
                        print("\(TAG): Received classic data: \(string)")
                        DispatchQueue.main.async {
                            self.receivedDataSink?(string)
                        }
                    }
                } else if bytesRead < 0 {
                    print("\(TAG): Classic read error")
                    DispatchQueue.main.async {
                        self.receivedDataSink?(FlutterError(code: "READ_ERROR", message: "Failed to read data", details: nil))
                    }
                    break
                }
            }
        }
    }

    private func checkClassicStatus(result: @escaping FlutterResult) {
        guard let outputStream = session?.outputStream, outputStream.hasSpaceAvailable else {
            result(FlutterError(code: "NOT_CONNECTED", message: "Not connected", details: nil))
            return
        }

        // ESC v for status
        let statusCommand = Data([0x1B, 0x76])
        let bytesWritten = statusCommand.withUnsafeBytes { buffer in
            outputStream.write(buffer.baseAddress!, maxLength: buffer.count)
        }

        if bytesWritten > 0 {
            // Simulate status response (actual response depends on device)
            let statusMap = ["online": true, "paperOut": false]
            print("\(TAG): Classic status: \(statusMap)")
            result(statusMap)
        } else {
            result(FlutterError(code: "STATUS_ERROR", message: "Failed to check status", details: nil))
        }
    }

    // MARK: - BLE Methods
    private func startBleScanning(timeout: Int) {
        print("\(TAG): Starting BLE scanning")
        if isBleScanning {
            stopBleScanning()
        }

        centralManager?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        isBleScanning = true

        if timeout > 0 {
            scanTimeoutTimer?.invalidate()
            scanTimeoutTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(timeout), repeats: false) { _ in
                self.stopBleScanning()
                self.discoveredDevicesSink?(["event": "timeout", "message": "BLE scan stopped after \(timeout) seconds"])
            }
        }
    }

    private func stopBleScanning() {
        print("\(TAG): Stopping BLE scanning")
        centralManager?.stopScan()
        isBleScanning = false
        scanTimeoutTimer?.invalidate()
        scanTimeoutTimer = nil
    }

    private func connectToBleDevice(address: String, result: @escaping FlutterResult) {
        guard let uuid = UUID(uuidString: address),
              let peripheral = centralManager?.retrievePeripherals(withIdentifiers: [uuid]).first else {
            print("\(TAG): BLE device not found: \(address)")
            result(FlutterError(code: "DEVICE_NOT_FOUND", message: "Device not found", details: nil))
            return
        }

        disconnectBle()
        centralManager?.connect(peripheral, options: nil)
        print("\(TAG): Initiating BLE connection to \(address)")
        result(nil)
    }

    private func disconnectBle() {
        print("\(TAG): Disconnecting BLE")
        if let peripheral = connectedPeripheral {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
        connectedPeripheral = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
    }

    private func sendBleData(data: String, result: @escaping FlutterResult) {
        guard let peripheral = connectedPeripheral,
              let characteristic = writeCharacteristic,
              let data = data.data(using: .utf8) else {
            print("\(TAG): BLE not connected or characteristic unavailable")
            result(FlutterError(code: "NOT_CONNECTED", message: "Not connected or characteristic unavailable", details: nil))
            return
        }

        peripheral.writeValue(data, for: characteristic, type: characteristic.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse)
        print("\(TAG): Sent BLE data: \(data)")
        result(nil)
    }

    private func checkBleStatus(result: @escaping FlutterResult) {
        guard let peripheral = connectedPeripheral,
              let characteristic = notifyCharacteristic else {
            result(FlutterError(code: "NOT_CONNECTED", message: "Not connected or characteristic unavailable", details: nil))
            return
        }

        peripheral.readValue(for: characteristic)
        // Assume status is handled via characteristic update
        print("\(TAG): Initiated BLE status check")
        result(["online": true, "paperOut": false]) // Placeholder
    }

    // MARK: - Pairing and Paired Devices
    private func pairDevice(address: String, result: @escaping FlutterResult) {
        // iOS handles pairing automatically via the system Bluetooth picker for Classic
        // For BLE, pairing is managed by CoreBluetooth during connection
        print("\(TAG): Pairing initiated for \(address)")
        result("Pairing initiated")
    }

    private func getPairedDevices(result: @escaping FlutterResult) {
        var deviceList: [[String: Any]] = []

        // Classic devices
        let classicDevices = accessoryManager.connectedAccessories.map { accessory ->
            [
                "name": accessory.name ?? "Unknown",
                "address": accessory.serialNumber,
                "uuids": [sppProtocolString],
                "type": "Classic",
                "isBle": false
            ]
        }
        deviceList.append(contentsOf: classicDevices)

        // BLE devices (retrieve connected or known peripherals)
        if let peripherals = centralManager?.retrieveConnectedPeripherals(withServices: []) {
            let bleDevices = peripherals.map { peripheral ->
                [
                    "name": peripheral.name ?? "Unknown",
                    "address": peripheral.identifier.uuidString,
                    "uuids": [],
                    "type": "BLE",
                    "isBle": true
                ]
            }
            deviceList.append(contentsOf: bleDevices)
        }

        print("\(TAG): Fetched \(deviceList.count) paired devices")
        result(deviceList)
    }

    private func emitPairedDevices() {
        guard let sink = pairedDevicesSink else { return }

        var deviceList: [[String: Any]] = []

        // Classic devices
        let classicDevices = accessoryManager.connectedAccessories.map { accessory ->
            [
                "name": accessory.name ?? "Unknown",
                "address": accessory.serialNumber,
                "uuids": [sppProtocolString],
                "type": "Classic",
                "isBle": false
            ]
        }
        deviceList.append(contentsOf: classicDevices)

        // BLE devices
        if let peripherals = centralManager?.retrieveConnectedPeripherals(withServices: []) {
            let bleDevices = peripherals.map { peripheral ->
                [
                    "name": peripheral.name ?? "Unknown",
                    "address": peripheral.identifier.uuidString,
                    "uuids": [],
                    "type": "BLE",
                    "isBle": true
                ]
            }
            deviceList.append(contentsOf: bleDevices)
        }

        print("\(TAG): Emitting \(deviceList.count) paired devices")
        sink(deviceList)
    }

    // MARK: - NSStreamDelegate
    public func stream(_ aStream: NSStream, handleEvent eventCode: NSStream.Event) {
        switch eventCode {
        case .hasBytesAvailable:
            if aStream == session?.inputStream {
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
                defer { buffer.deallocate() }
                if let bytesRead = session?.inputStream?.read(buffer, maxLength: 1024), bytesRead > 0 {
                    let data = Data(bytes: buffer, count: bytesRead)
                    if let string = String(data: data, encoding: .utf8) {
                        print("\(TAG): Received classic data: \(string)")
                        receivedDataSink?(string)
                    }
                }
            }
        case .errorOccurred:
            print("\(TAG): Stream error occurred")
            receivedDataSink?(FlutterError(code: "STREAM_ERROR", message: "Stream error", details: nil))
        case .endEncountered:
            print("\(TAG): Stream ended")
            disconnectClassic()
        default:
            break
        }
    }

    deinit {
        disconnectBle()
        disconnectClassic()
        NotificationCenter.default.removeObserver(self)
    }
}