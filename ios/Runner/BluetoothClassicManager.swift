import ExternalAccessory
import Foundation

class BluetoothClassicManager: NSObject, StreamDelegate {
    private let accessoryManager = EAAccessoryManager.shared()
    private var session: EASession?
    private let protocolString: String // e.g., "com.epson.printer"
    private let eventCallback: (BluetoothEvent) -> Void
    private let logTag = "BluetoothClassicManager"
    private var keepAliveTimer: Timer?
    
    init(protocolString: String, eventCallback: @escaping (BluetoothEvent) -> Void) {
        self.protocolString = protocolString
        self.eventCallback = eventCallback
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(accessoryDidConnect), name: .EAAccessoryDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(accessoryDidDisconnect), name: .EAAccessoryDidDisconnect, object: nil)
        accessoryManager.registerForLocalNotifications()
    }
    
    @objc func accessoryDidConnect(notification: Notification) {
        guard let accessory = notification.userInfo?[EAAccessoryKey] as? EAAccessory else { return }
        print("\(logTag): Accessory connected: \(accessory.name)")
        eventCallback(BluetoothEvent.receivedData(BluetoothEvent.ReceivedData(data: "Classic Connected")))
    }
    
    @objc func accessoryDidDisconnect(notification: Notification) {
        guard let accessory = notification.userInfo?[EAAccessoryKey] as? EAAccessory else { return }
        print("\(logTag): Accessory disconnected: \(accessory.name)")
        session = nil
        eventCallback(BluetoothEvent.receivedData(BluetoothEvent.ReceivedData(data: "Classic Disconnected")))
    }
    
    func startScanning(timeoutSeconds: Int?, result: @escaping FlutterResult) {
        print("\(logTag): Starting Classic Bluetooth discovery")
        let accessories = accessoryManager.connectedAccessories.filter { $0.protocolStrings.contains(protocolString) }
        accessories.forEach { accessory in
            let name = accessory.name.isEmpty ? "Unknown" : accessory.name
            print("\(logTag): Found accessory: \(name) (\(accessory.connectionID))")
            eventCallback(BluetoothEvent.discoveredDevice(BluetoothEvent.DiscoveredDevice(
                name: name,
                address: "\(accessory.connectionID)",
                uuids: accessory.protocolStrings,
                type: "Classic",
                isBle: false,
                event: nil,
                message: nil
            )))
        }
        result(nil)
        
        if let timeout = timeoutSeconds, timeout > 0 {
            Timer.scheduledTimer(withTimeInterval: TimeInterval(timeout), repeats: false) { [weak self] _ in
                print("\(self?.logTag): Classic discovery stopped due to timeout")
                self?.eventCallback(BluetoothEvent.discoveredDevice(BluetoothEvent.DiscoveredDevice(
                    name: "",
                    address: "",
                    uuids: [],
                    type: "",
                    isBle: false,
                    event: "timeout",
                    message: "Classic discovery stopped after \(timeout) seconds"
                )))
            }
        }
    }
    
    func stopScanning(result: @escaping FlutterResult) {
        print("\(logTag): Stopping Classic Bluetooth discovery")
        result(nil)
    }
    
    func getPairedDevices() -> [[String: Any]] {
        let accessories = accessoryManager.connectedAccessories.filter { $0.protocolStrings.contains(protocolString) }
        let devices = accessories.map { accessory in
            [
                "name": accessory.name.isEmpty ? "Unknown" : accessory.name,
                "address": "\(accessory.connectionID)",
                "uuids": accessory.protocolStrings,
                "type": "Classic",
                "isBle": false
            ]
        }
        print("\(logTag): Fetched \(devices.count) paired Classic devices")
        return devices
    }
    
    func connectToDevice(address: String, result: @escaping FlutterResult) {
        guard let connectionID = Int(address) else {
            print("\(logTag): Invalid connection ID: \(address)")
            result(FlutterError(code: "INVALID_ADDRESS", message: "Invalid connection ID", details: nil))
            return
        }
        
        let accessories = accessoryManager.connectedAccessories.filter { $0.connectionID == connectionID && $0.protocolStrings.contains(protocolString) }
        guard let accessory = accessories.first else {
            print("\(logTag): Accessory not found for ID: \(address)")
            result(FlutterError(code: "DEVICE_NOT_FOUND", message: "Accessory not found", details: nil))
            return
        }
        
        session = EASession(accessory: accessory, forProtocol: protocolString)
        if let session = session {
            session.inputStream?.delegate = self
            session.inputStream?.schedule(in: .main, forMode: .default)
            session.inputStream?.open()
            session.outputStream?.delegate = self
            session.outputStream?.schedule(in: .main, forMode: .default)
            session.outputStream?.open()
            print("\(logTag): Connected to accessory: \(accessory.name)")
            startKeepAlive()
            result(nil)
        } else {
            print("\(logTag): Failed to create session")
            result(FlutterError(code: "CONNECT_ERROR", message: "Failed to create session", details: nil))
        }
    }
    
    func disconnect(result: @escaping FlutterResult) {
        print("\(logTag): Disconnecting Classic Bluetooth")
        stopKeepAlive()
        session?.inputStream?.close()
        session?.outputStream?.close()
        session = nil
        result(nil)
    }
    
    func sendReceipt(data: String, result: @escaping FlutterResult) {
        guard let outputStream = session?.outputStream, outputStream.hasSpaceAvailable else {
            print("\(logTag): Not connected or output stream unavailable")
            result(FlutterError(code: "NOT_CONNECTED", message: "Not connected to accessory", details: nil))
            return
        }
        
        let initialize = Data([0x1B, 0x40])
        let centerAlign = Data([0x1B, 0x61, 0x01])
        let printText = data.data(using: .ascii) ?? Data()
        let lineFeed = Data([0x0A])
        let cutPaper = Data([0x1D, 0x56, 0x00])
        let escPosData = initialize + centerAlign + printText + lineFeed + cutPaper
        
        let bytesWritten = escPosData.withUnsafeBytes { buffer in
            outputStream.write(buffer.baseAddress!, maxLength: buffer.count)
        }
        
        if bytesWritten > 0 {
            print("\(logTag): Sent ESC/POS data: \(data)")
            result(nil)
        } else {
            print("\(logTag): Failed to send data")
            result(FlutterError(code: "SEND_ERROR", message: "Failed to send data", details: nil))
        }
    }
    
    func checkStatus(result: @escaping FlutterResult) {
        guard let outputStream = session?.outputStream, outputStream.hasSpaceAvailable else {
            print("\(logTag): Not connected or output stream unavailable")
            result(FlutterError(code: "NOT_CONNECTED", message: "Not connected to accessory", details: nil))
            return
        }
        
        let statusRequest = Data([0x1B, 0x76])
        let bytesWritten = statusRequest.withUnsafeBytes { buffer in
            outputStream.write(buffer.baseAddress!, maxLength: buffer.count)
        }
        
        if bytesWritten > 0 {
            print("\(logTag): Initiated status check")
            result(["online": true, "paperOut": false])
        } else {
            print("\(logTag): Failed to initiate status check")
            result(FlutterError(code: "STATUS_ERROR", message: "Failed to check status", details: nil))
        }
    }
    
    private func startKeepAlive() {
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            guard let outputStream = self?.session?.outputStream, outputStream.hasSpaceAvailable else { return }
            let keepAlive = Data([0x1B, 0x76])
            let bytesWritten = keepAlive.withUnsafeBytes { buffer in
                outputStream.write(buffer.baseAddress!, maxLength: buffer.count)
            }
            print("\(self?.logTag): Sent keep-alive: \(bytesWritten > 0 ? "Success" : "Failed")")
        }
    }
    
    private func stopKeepAlive() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
    }
    
    func cleanup() {
        print("\(logTag): Cleaning up Classic Bluetooth")
        stopKeepAlive()
        session?.inputStream?.close()
        session?.outputStream?.close()
        session = nil
        NotificationCenter.default.removeObserver(self)
        accessoryManager.unregisterForLocalNotifications()
    }
    
    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .hasBytesAvailable:
            if let inputStream = aStream as? InputStream {
                var buffer = [UInt8](repeating: 0, count: 1024)
                let bytesRead = inputStream.read(&buffer, maxLength: buffer.count)
                if bytesRead > 0, let data = String(bytes: buffer[0..<bytesRead], encoding: .utf8) {
                    print("\(logTag): Received data: \(data)")
                    eventCallback(BluetoothEvent.receivedData(BluetoothEvent.ReceivedData(data: data)))
                }
            }
        case .errorOccurred:
            print("\(logTag): Stream error")
            eventCallback(BluetoothEvent.error(BluetoothEvent.Error(code: "STREAM_ERROR", message: "Stream error occurred")))
        default:
            break
        }
    }
}
