import CoreBluetooth
import Foundation

class BluetoothLeManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let serviceUUID = CBUUID(string: "0000180d-0000-1000-8000-00805f9b34fb")
    private let characteristicUUID = CBUUID(string: "00002a37-0000-1000-8000-00805f9b34fb")
    private let descriptorUUID = CBUUID(string: "00002902-0000-1000-8000-00805f9b34fb")
    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var targetCharacteristic: CBCharacteristic?
    private var isScanning = false
    private var scanTimer: Timer?
    private let eventCallback: (BluetoothEvent) -> Void
    private let logTag = "BluetoothLeManager"
    
    init(eventCallback: @escaping (BluetoothEvent) -> Void) {
        self.eventCallback = eventCallback
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }
    
    // MARK: - CBCentralManagerDelegate
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            print("\(logTag): Bluetooth is powered on")
        case .poweredOff:
            print("\(logTag): Bluetooth is powered off")
            eventCallback(.Error(code: "BLUETOOTH_NOT_AVAILABLE", message: "Bluetooth is powered off"))
        case .unauthorized:
            print("\(logTag): Bluetooth unauthorized")
            eventCallback(.Error(code: "BLUETOOTH_UNAUTHORIZED", message: "Bluetooth access not authorized"))
        case .unsupported:
            print("\(logTag): Bluetooth unsupported")
            eventCallback(.Error(code: "BLUETOOTH_NOT_AVAILABLE", message: "Bluetooth is not supported on this device"))
        case .resetting:
            print("\(logTag): Bluetooth resetting")
        case .unknown:
            print("\(logTag): Bluetooth state unknown")
        @unknown default:
            print("\(logTag): Bluetooth state: \(central.state.rawValue)")
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? "Unknown"
        let address = peripheral.identifier.uuidString
        let serviceUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map { $0.uuidString } ?? []
        print("\(logTag): Found BLE device: \(name) (\(address))")
        eventCallback(.DiscoveredDevice(
            name: name,
            address: address,
            uuids: serviceUUIDs,
            type: "BLE",
            isBle: true,
            event: nil,
            message: nil
        ))
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("\(logTag): BLE connected to \(peripheral.name ?? "Unknown")")
        connectedPeripheral = peripheral
        peripheral.delegate = self
        peripheral.discoverServices([serviceUUID])
        eventCallback(.ReceivedData(data: "BLE Connected"))
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        print("\(logTag): BLE disconnected")
        connectedPeripheral = nil
        targetCharacteristic = nil
        eventCallback(.ReceivedData(data: "BLE Disconnected"))
        if let error = error {
            eventCallback(.Error(code: "BLE_DISCONNECT_ERROR", message: error.localizedDescription))
        }
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("\(logTag): Failed to connect: \(error?.localizedDescription ?? "Unknown error")")
        eventCallback(.Error(code: "BLE_CONNECT_ERROR", message: error?.localizedDescription ?? "Failed to connect to device"))
    }
    
    // MARK: - CBPeripheralDelegate
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            print("\(logTag): Service discovery failed: \(error.localizedDescription)")
            eventCallback(.Error(code: "BLE_SERVICE_ERROR", message: "Service discovery failed"))
            return
        }
        
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            print("\(logTag): Service \(serviceUUID.uuidString) not found")
            eventCallback(.Error(code: "BLE_SERVICE_ERROR", message: "Required service not found"))
            return
        }
        
        peripheral.discoverCharacteristics([characteristicUUID], for: service)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            print("\(logTag): Characteristic discovery failed: \(error.localizedDescription)")
            eventCallback(.Error(code: "BLE_CHARACTERISTIC_ERROR", message: "Characteristic discovery failed"))
            return
        }
        
        guard let characteristic = service.characteristics?.first(where: { $0.uuid == characteristicUUID }) else {
            print("\(logTag): Characteristic \(characteristicUUID.uuidString) not found")
            eventCallback(.Error(code: "BLE_CHARACTERISTIC_ERROR", message: "Required characteristic not found"))
            return
        }
        
        targetCharacteristic = characteristic
        if characteristic.properties.contains(.notify) {
            peripheral.setNotifyValue(true, for: characteristic)
            peripheral.discoverDescriptors(for: characteristic)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("\(logTag): Descriptor discovery failed: \(error.localizedDescription)")
            eventCallback(.Error(code: "BLE_DESCRIPTOR_ERROR", message: "Descriptor discovery failed"))
            return
        }
        
        if let descriptor = characteristic.descriptors?.first(where: { $0.uuid == descriptorUUID }) {
            peripheral.writeValue(Data([0x01, 0x00]), for: descriptor)
            print("\(logTag): Enabled notifications for characteristic \(characteristicUUID.uuidString)")
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("\(logTag): Characteristic read failed: \(error.localizedDescription)")
            eventCallback(.Error(code: "BLE_READ_ERROR", message: "Characteristic read failed"))
            return
        }
        
        if let value = characteristic.value, let data = String(data: value, encoding: .utf8) {
            print("\(logTag): Received BLE data: \(data)")
            eventCallback(.ReceivedData(data: data))
        } else {
            print("\(logTag): Failed to decode characteristic value")
            eventCallback(.Error(code: "BLE_READ_ERROR", message: "Failed to decode characteristic value"))
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("\(logTag): Characteristic write failed: \(error.localizedDescription)")
            eventCallback(.Error(code: "BLE_WRITE_ERROR", message: "Characteristic write failed"))
            return
        }
        print("\(logTag): BLE characteristic write successful")
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor descriptor: CBDescriptor, error: Error?) {
        if let error = error {
            print("\(logTag): Descriptor write failed: \(error.localizedDescription)")
            eventCallback(.Error(code: "BLE_DESCRIPTOR_ERROR", message: "Descriptor write failed"))
            return
        }
        print("\(logTag): Descriptor write successful")
    }
    
    // MARK: - Public Methods
    func startScanning(timeoutSeconds: Int?, result: @escaping FlutterResult) {
        print("\(logTag): Starting BLE scanning")
        guard centralManager.state == .poweredOn else {
            print("\(logTag): Bluetooth not available")
            result(FlutterError(code: "BLUETOOTH_NOT_AVAILABLE", message: "Bluetooth is not available or not enabled", details: nil))
            return
        }
        
        if isScanning {
            stopScanningInternal()
            print("\(logTag): Stopped existing BLE scan")
        }
        
        centralManager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        isScanning = true
        print("\(logTag): BLE scan started successfully")
        result(nil)
        
        if let timeout = timeoutSeconds, timeout > 0 {
            scanTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(timeout), repeats: false) { [weak self] _ in
                if self?.isScanning == true {
                    self?.stopScanningInternal()
                    print("\(logTag): BLE scan stopped due to timeout")
                    self?.eventCallback(.DiscoveredDevice(
                        name: "",
                        address: "",
                        uuids: [],
                        type: "",
                        isBle: true,
                        event: "timeout",
                        message: "BLE scan stopped after \(timeout) seconds"
                    ))
                }
            }
        }
    }
    
    func stopScanning(result: @escaping FlutterResult) {
        print("\(logTag): Stopping BLE scanning")
        stopScanningInternal()
        result(nil)
    }
    
    private func stopScanningInternal() {
        if isScanning {
            centralManager.stopScan()
            isScanning = false
            scanTimer?.invalidate()
            scanTimer = nil
            print("\(logTag): BLE scan stopped")
        }
    }
    
    func getPairedDevices() -> [[String: Any]] {
        guard centralManager.state == .poweredOn else {
            print("\(logTag): Bluetooth not available")
            return []
        }
        
        let peripherals = centralManager.retrieveConnectedPeripherals(withServices: [serviceUUID])
        return peripherals.map { peripheral in
            [
                "name": peripheral.name ?? "Unknown",
                "address": peripheral.identifier.uuidString,
                "uuids": [],
                "type": "BLE",
                "isBle": true
            ]
        }.also { print("\(logTag): Fetched \($0.count) connected BLE devices") }
    }
    
    func connectToDevice(address: String, result: @escaping FlutterResult) {
        guard centralManager.state == .poweredOn else {
            print("\(logTag): Bluetooth not available")
            result(FlutterError(code: "BLUETOOTH_NOT_AVAILABLE", message: "Bluetooth is not available", details: nil))
            return
        }
        
        guard let uuid = UUID(uuidString: address) else {
            print("\(logTag): Invalid device address: \(address)")
            result(FlutterError(code: "INVALID_ADDRESS", message: "Invalid device address", details: nil))
            return
        }
        
        stopScanningInternal()
        let peripherals = centralManager.retrievePeripherals(withIdentifiers: [uuid])
        guard let peripheral = peripherals.first else {
            print("\(logTag): Device not found for address: \(address)")
            result(FlutterError(code: "DEVICE_NOT_FOUND", message: "Device not found", details: nil))
            return
        }
        
        centralManager.connect(peripheral, options: nil)
        print("\(logTag): Initiated BLE connection to \(address)")
        result(nil)
    }
    
    func disconnect(result: @escaping FlutterResult) {
        print("\(logTag): Disconnecting BLE")
        if let peripheral = connectedPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
            connectedPeripheral = nil
            targetCharacteristic = nil
            print("\(logTag): BLE disconnected successfully")
        }
        result(nil)
    }
    
    func sendData(data: String, result: @escaping FlutterResult) {
        guard let peripheral = connectedPeripheral, let characteristic = targetCharacteristic else {
            print("\(logTag): Not connected or characteristic not found")
            result(FlutterError(code: "NOT_CONNECTED", message: "Not connected to BLE device or characteristic not found", details: nil))
            return
        }
        
        guard let dataBytes = data.data(using: .utf8) else {
            print("\(logTag): Invalid data format")
            result(FlutterError(code: "INVALID_DATA", message: "Failed to convert data to bytes", details: nil))
            return
        }
        
        peripheral.writeValue(dataBytes, for: characteristic, type: .withResponse)
        print("\(logTag): Sent BLE data: \(data)")
        result(nil)
    }
    
    func checkStatus(result: @escaping FlutterResult) {
        guard let peripheral = connectedPeripheral, let characteristic = targetCharacteristic else {
            print("\(logTag): Not connected or characteristic not found")
            result(FlutterError(code: "NOT_CONNECTED", message: "Not connected to BLE device or characteristic not found", details: nil))
            return
        }
        
        peripheral.readValue(for: characteristic)
        print("\(logTag): Initiated BLE status check")
        // Match Kotlin's hardcoded response
        result(["online": true, "paperOut": false])
    }
    
    func cleanup() {
        print("\(logTag): Cleaning up BluetoothLeManager")
        stopScanningInternal()
        if let peripheral = connectedPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        connectedPeripheral = nil
        targetCharacteristic = nil
    }
}