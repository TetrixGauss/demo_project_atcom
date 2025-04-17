import Foundation
import ExternalAccessory

class BluetoothClassicManager: NSObject {
    private var eventCallback: (BluetoothEvent) -> Void
    private var connectedAccessory: EAAccessory?
    private var session: EASession?
    private var sendDataResult: FlutterResult?

    init(eventCallback: @escaping (BluetoothEvent) -> Void) {
        self.eventCallback = eventCallback
        super.init()
        registerForNotifications()
    }

    func startScanning(result: @escaping FlutterResult) {
        print("Started Classic Bluetooth scanning for all devices")
        // List already paired accessories
        let accessories = EAAccessoryManager.shared().connectedAccessories
        print("Initial paired accessories: \(accessories.map { "\($0.name): \($0.protocolStrings)" })")
        for accessory in accessories {
            notifyAccessoryConnected(accessory)
        }
        // Show picker for all discoverable devices
        EAAccessoryManager.shared().showBluetoothAccessoryPicker(withNameFilter: nil) { error in
            if let error = error {
                print("Bluetooth picker error: \(error.localizedDescription)")
                let nsError = error as NSError
                switch nsError.code {
                case EABluetoothAccessoryPickerError.alreadyConnected.rawValue:
                    print("Accessory already connected, proceeding")
                    result(nil)
                case EABluetoothAccessoryPickerError.resultCancelled.rawValue:
                    print("Pairing cancelled by user")
                    result(FlutterError(code: "PICKER_CANCELLED", message: "Pairing cancelled by user", details: nil))
                    return
                case EABluetoothAccessoryPickerError.resultFailed.rawValue:
                    print("Pairing failed")
                    result(FlutterError(code: "PICKER_FAILED", message: "Failed to pair device", details: error.localizedDescription))
                    return
                default:
                    print("Unknown picker error: \(nsError.code)")
                    result(FlutterError(code: "PICKER_ERROR", message: error.localizedDescription, details: nil))
                    return
                }
            }
            // Stream newly paired accessories
            let updatedAccessories = EAAccessoryManager.shared().connectedAccessories
            print("Paired accessories after picker: \(updatedAccessories.map { "\($0.name): \($0.protocolStrings)" })")
            for accessory in updatedAccessories {
                self.notifyAccessoryConnected(accessory)
            }
            result(nil)
        }
    }

    func pairDevice(deviceName: String, result: @escaping FlutterResult) {
        print("Initiating pairing with device: \(deviceName)")
        let predicate = NSPredicate(format: "name ==[cd] %@", deviceName)
        EAAccessoryManager.shared().showBluetoothAccessoryPicker(withNameFilter: predicate) { error in
            if let error = error {
                print("Pairing error for \(deviceName): \(error.localizedDescription)")
                let nsError = error as NSError
                switch nsError.code {
                case EABluetoothAccessoryPickerError.alreadyConnected.rawValue:
                    print("Device \(deviceName) already paired")
                    if let accessory = EAAccessoryManager.shared().connectedAccessories.first(where: { $0.name == deviceName }) {
                        self.notifyAccessoryConnected(accessory)
                    }
                    result(nil)
                case EABluetoothAccessoryPickerError.resultCancelled.rawValue:
                    print("Pairing cancelled for \(deviceName)")
                    result(FlutterError(code: "PICKER_CANCELLED", message: "Pairing cancelled by user", details: nil))
                case EABluetoothAccessoryPickerError.resultFailed.rawValue:
                    print("Pairing failed for \(deviceName)")
                    result(FlutterError(code: "PICKER_FAILED", message: "Failed to pair \(deviceName)", details: error.localizedDescription))
                default:
                    print("Unknown pairing error for \(deviceName): \(nsError.code)")
                    result(FlutterError(code: "PICKER_ERROR", message: error.localizedDescription, details: nil))
                }
                return
            }
            if let accessory = EAAccessoryManager.shared().connectedAccessories.first(where: { $0.name == deviceName }) {
                print("Successfully paired \(deviceName)")
                self.notifyAccessoryConnected(accessory)
            } else {
                print("Paired device \(deviceName) not found in connected accessories")
            }
            result(nil)
        }
    }

    func stopScanning(result: @escaping FlutterResult) {
        print("Stopped Classic Bluetooth scanning")
        result(nil)
    }

    func connectToDevice(address: String, result: @escaping FlutterResult) {
        guard let accessory = EAAccessoryManager.shared().connectedAccessories.first(where: { $0.serialNumber == address || $0.name == address }) else {
            result(FlutterError(code: "DEVICE_NOT_FOUND", message: "Accessory not found for address: \(address)", details: nil))
            return
        }
        guard let protocolString = accessory.protocolStrings.first else {
            result(FlutterError(code: "NO_PROTOCOL", message: "No protocol strings available for accessory", details: nil))
            return
        }
        connectedAccessory = accessory
        session = EASession(accessory: accessory, forProtocol: protocolString)
        if let session = session {
            session.inputStream?.delegate = self
            session.inputStream?.schedule(in: .main, forMode: .default)
            session.inputStream?.open()
            session.outputStream?.delegate = self
            session.outputStream?.schedule(in: .main, forMode: .default)
            session.outputStream?.open()
            print("Connected to accessory: \(accessory.name) (\(accessory.serialNumber))")
            result(nil)
        } else {
            result(FlutterError(code: "SESSION_FAILED", message: "Failed to create session for accessory", details: nil))
        }
    }

    func disconnect(result: @escaping FlutterResult) {
        if let session = session {
            session.inputStream?.close()
            session.inputStream?.remove(from: .main, forMode: .default)
            session.outputStream?.close()
            session.outputStream?.remove(from: .main, forMode: .default)
            self.session = nil
        }
        connectedAccessory = nil
        print("Disconnected Classic Bluetooth accessory")
        result(nil)
    }

    func sendReceipt(data: String, result: @escaping FlutterResult) {
        guard let session = session, let outputStream = session.outputStream, outputStream.hasSpaceAvailable else {
            result(FlutterError(code: "NOT_CONNECTED", message: "Not connected or output stream unavailable", details: nil))
            return
        }
        guard let dataBytes = data.data(using: .ascii) else {
            result(FlutterError(code: "INVALID_DATA", message: "Failed to convert data to bytes", details: nil))
            return
        }
        sendDataResult = result
        let bytesWritten = dataBytes.withUnsafeBytes { buffer in
            outputStream.write(buffer.baseAddress!, maxLength: buffer.count)
        }
        if bytesWritten > 0 {
            print("Sent data to accessory: \(dataBytes.hexString)")
            result(nil)
        } else {
            result(FlutterError(code: "WRITE_FAILED", message: "Failed to write data to output stream", details: nil))
        }
    }

    func checkStatus(result: @escaping FlutterResult) {
        result(connectedAccessory != nil ? "CONNECTED" : "DISCONNECTED")
    }

    func getPairedDevices() -> [[String: Any]] {
        let accessories = EAAccessoryManager.shared().connectedAccessories
        print("Listing paired devices: \(accessories.map { "\($0.name): \($0.protocolStrings)" })")
        return accessories.map { accessory in
            [
                "name": accessory.name,
                "address": accessory.serialNumber.isEmpty ? accessory.name : accessory.serialNumber,
                "uuids": accessory.protocolStrings,
                "type": "Classic",
                "isBle": false
            ]
        }
    }

    func cleanup() {
        disconnect(result: { _ in })
        NotificationCenter.default.removeObserver(self)
    }

    private func registerForNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(accessoryDidConnect),
            name: .EAAccessoryDidConnect,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(accessoryDidDisconnect),
            name: .EAAccessoryDidDisconnect,
            object: nil
        )
        EAAccessoryManager.shared().registerForLocalNotifications()
    }

    @objc func accessoryDidConnect(notification: Notification) {
        guard let accessory = notification.userInfo?[EAAccessoryKey] as? EAAccessory else { return }
        print("Accessory paired: \(accessory.name) (\(accessory.serialNumber)), protocols: \(accessory.protocolStrings)")
        notifyAccessoryConnected(accessory)
    }

    @objc func accessoryDidDisconnect(notification: Notification) {
        guard let accessory = notification.userInfo?[EAAccessoryKey] as? EAAccessory else { return }
        print("Accessory unpaired: \(accessory.name) (\(accessory.serialNumber))")
        if connectedAccessory?.serialNumber == accessory.serialNumber {
            disconnect(result: { _ in })
        }
        let device = BluetoothEvent.DiscoveredDevice(
            name: accessory.name,
            address: accessory.serialNumber.isEmpty ? accessory.name : accessory.serialNumber,
            uuids: accessory.protocolStrings,
            type: "Classic",
            isBle: false,
            event: "disconnected",
            message: nil
        )
        eventCallback(.discoveredDevice(device))
    }

    private func notifyAccessoryConnected(_ accessory: EAAccessory) {
        let address = accessory.serialNumber.isEmpty ? accessory.name : accessory.serialNumber
        let device = BluetoothEvent.DiscoveredDevice(
            name: accessory.name,
            address: address,
            uuids: accessory.protocolStrings,
            type: "Classic",
            isBle: false,
            event: "paired",
            message: nil
        )
        print("Notifying paired accessory: \(device.name) (\(device.address))")
        eventCallback(.discoveredDevice(device))
    }
}

extension BluetoothClassicManager: StreamDelegate {
    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .openCompleted:
            print("Stream opened for accessory: \(connectedAccessory?.name ?? "Unknown")")
        case .hasBytesAvailable:
            print("Data available from accessory")
        case .errorOccurred:
            print("Stream error for accessory: \(connectedAccessory?.name ?? "Unknown")")
        case .endEncountered:
            print("Stream ended for accessory: \(connectedAccessory?.name ?? "Unknown")")
            disconnect(result: { _ in })
        default:
            break
        }
    }
}

extension Data {
    var hexString: String {
        return map { String(format: "%02x", $0) }.joined()
    }
}