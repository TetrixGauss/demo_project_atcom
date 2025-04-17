import Foundation
import CoreBluetooth

class BluetoothLeManager: NSObject {
    private var centralManager: CBCentralManager!
    private var eventCallback: (BluetoothEvent) -> Void
    private var discoveredPeripherals: [String: CBPeripheral] = [:]
    private var connectedPeripheral: CBPeripheral?
    private var connectionResult: FlutterResult?
    private var writeCharacteristic: CBCharacteristic? // Store the writable characteristic
    private var sendDataResult: FlutterResult?
    
    init(eventCallback: @escaping (BluetoothEvent) -> Void) {
        self.eventCallback = eventCallback
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }
    
    func startScanning(timeoutSeconds: Int?, result: @escaping FlutterResult) {
        guard centralManager.state == .poweredOn else {
            result(FlutterError(code: "BLUETOOTH_OFF", message: "Bluetooth is not powered on", details: nil))
            return
        }
        discoveredPeripherals.removeAll()
        centralManager.scanForPeripherals(withServices: nil, options: nil)
        print("Started BLE scanning")
        if let timeout = timeoutSeconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(timeout)) { [weak self] in
                self?.stopScanning(result: { _ in })
            }
        }
        result(nil)
    }
    
    func stopScanning(result: @escaping FlutterResult) {
        centralManager.stopScan()
        print("Stopped BLE scanning")
        result(nil)
    }
    
    func connectToDevice(address: String, result: @escaping FlutterResult) {
        guard centralManager.state == .poweredOn else {
            result(FlutterError(code: "BLUETOOTH_OFF", message: "Bluetooth is not powered on", details: nil))
            return
        }
        guard let uuid = UUID(uuidString: address) else {
            result(FlutterError(code: "INVALID_ADDRESS", message: "Invalid UUID: \(address)", details: nil))
            return
        }
        var peripheral: CBPeripheral? = discoveredPeripherals[uuid.uuidString]
        if peripheral == nil {
            peripheral = centralManager.retrievePeripherals(withIdentifiers: [uuid]).first
        }
        guard let targetPeripheral = peripheral else {
            result(FlutterError(code: "DEVICE_NOT_FOUND", message: "Peripheral not found for address: \(address)", details: nil))
            return
        }
        discoveredPeripherals[uuid.uuidString] = targetPeripheral
        targetPeripheral.delegate = self
        connectionResult = result
        centralManager.connect(targetPeripheral, options: nil)
        print("Initiating connection to peripheral: \(targetPeripheral.name ?? "Unknown") (\(uuid.uuidString))")
    }
    
    func disconnect(result: @escaping FlutterResult) {
        if let peripheral = connectedPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
            print("Disconnecting peripheral: \(peripheral.name ?? "Unknown") (\(peripheral.identifier.uuidString))")
            connectedPeripheral = nil
            writeCharacteristic = nil
        }
        result(nil)
    }
    
    func sendData(data: String, result: @escaping FlutterResult) {
        guard let peripheral = connectedPeripheral, peripheral.state == .connected else {
            result(FlutterError(code: "NOT_CONNECTED", message: "No BLE peripheral connected", details: nil))
            return
        }
        guard let characteristic = writeCharacteristic else {
            result(FlutterError(code: "NO_CHARACTERISTIC", message: "Writable characteristic not found", details: nil))
            return
        }
        guard let dataBytes = data.data(using: .utf8) else {
            result(FlutterError(code: "INVALID_DATA", message: "Failed to convert data to bytes", details: nil))
            return
        }
        sendDataResult = result
        peripheral.writeValue(dataBytes, for: characteristic, type: .withResponse)
        print("Sending data to peripheral: \(peripheral.name ?? "Unknown"), data: \(data)")
    }
    
    func checkStatus(result: @escaping FlutterResult) {
        result(connectedPeripheral != nil ? "CONNECTED" : "DISCONNECTED")
    }
    
    func getPairedDevices() -> [[String: Any]] {
        return []
    }
    
    func getBluetoothState() -> CBManagerState {
        return centralManager.state
    }
    
    func cleanup() {
        if let peripheral = connectedPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        centralManager.stopScan()
        discoveredPeripherals.removeAll()
        connectedPeripheral = nil
        connectionResult = nil
        writeCharacteristic = nil
        sendDataResult = nil
    }
}

extension BluetoothLeManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        print("Central manager state updated: \(central.state.rawValue)")
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let uuid = peripheral.identifier.uuidString
        let name = peripheral.name ?? "Unknown"
        discoveredPeripherals[uuid] = peripheral
        let device = BluetoothEvent.DiscoveredDevice(
            name: name,
            address: uuid,
            uuids: (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map { $0.uuidString } ?? [],
            type: "BLE",
            isBle: true,
            event: nil,
            message: nil
        )
        print("Discovered peripheral: \(name) (\(uuid))")
        eventCallback(.discoveredDevice(device))
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("Connected to peripheral: \(peripheral.name ?? "Unknown") (\(peripheral.identifier.uuidString))")
        connectedPeripheral = peripheral
        peripheral.delegate = self
        peripheral.discoverServices(nil) // Discover all services
        connectionResult?(nil)
        connectionResult = nil
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("Failed to connect to peripheral: \(peripheral.name ?? "Unknown") (\(peripheral.identifier.uuidString)), error: \(error?.localizedDescription ?? "None")")
        discoveredPeripherals.removeValue(forKey: peripheral.identifier.uuidString)
        connectionResult?(FlutterError(code: "CONNECTION_FAILED", message: error?.localizedDescription ?? "Unknown error", details: nil))
        connectionResult = nil
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        print("Disconnected peripheral: \(peripheral.name ?? "Unknown") (\(peripheral.identifier.uuidString)), error: \(error?.localizedDescription ?? "None")")
        if connectedPeripheral?.identifier == peripheral.identifier {
            connectedPeripheral = nil
            writeCharacteristic = nil
        }
        discoveredPeripherals.removeValue(forKey: peripheral.identifier.uuidString)
    }
}

extension BluetoothLeManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            print("Failed to discover services for peripheral: \(peripheral.name ?? "Unknown"), error: \(error.localizedDescription)")
            return
        }
        print("Discovered services for peripheral: \(peripheral.name ?? "Unknown")")
        guard let services = peripheral.services else { return }
        for service in services {
            print("Service UUID: \(service.uuid)")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            print("Failed to discover characteristics for service \(service.uuid), error: \(error.localizedDescription)")
            return
        }
        print("Discovered characteristics for service: \(service.uuid)")
        guard let characteristics = service.characteristics else { return }
        for characteristic in characteristics {
            print("Characteristic UUID: \(characteristic.uuid), properties: \(characteristic.properties.rawValue)")
            // Look for a writable characteristic (e.g., for Star printers)
            if characteristic.properties.contains(.write) || characteristic.properties.contains(.writeWithoutResponse) {
                writeCharacteristic = characteristic
                print("Found writable characteristic: \(characteristic.uuid)")
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("Failed to write data to characteristic \(characteristic.uuid), error: \(error.localizedDescription)")
            sendDataResult?(FlutterError(code: "WRITE_FAILED", message: error.localizedDescription, details: nil))
        } else {
            print("Successfully wrote data to characteristic: \(characteristic.uuid)")
            sendDataResult?(nil)
        }
        sendDataResult = nil
    }
}