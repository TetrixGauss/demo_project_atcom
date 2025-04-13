import UIKit
import Flutter
import ExternalAccessory

@main
@objc class AppDelegate: FlutterAppDelegate {
    private let methodChannel = "com.example/bluetooth"
    private let discoveredDevicesChannel = "com.example/bluetooth_discovered_devices"
    private let receivedDataChannel = "com.example/bluetooth_received_data"

    private var accessoryManager: EAAccessoryManager
    private var session: EASession?
    private var discoveredDevicesSink: FlutterEventSink?
    private var receivedDataSink: FlutterEventSink?
    private var connectedAccessory: EAAccessory?

    override init() {
        accessoryManager = EAAccessoryManager.shared()
        super.init()
    }

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let controller = window?.rootViewController as! FlutterViewController

        // Method Channel
        let methodChannel = FlutterMethodChannel(
            name: methodChannel,
            binaryMessenger: controller.binaryMessenger
        )
        methodChannel.setMethodCallHandler { [weak self] (call, result) in
            guard let self = self else { return }
            switch call.method {
            case "startScanning":
                self.startScanning(result: result)
            case "stopScanning":
                self.stopScanning(result: result)
            case "connectToDevice":
                if let args = call.arguments as? [String: String], let protocolString = args["address"], let uuid = args["uuid"] {
                    self.connectToDevice(protocolString: protocolString, uuid: uuid, result: result)
                } else {
                    result(FlutterError(code: "INVALID_ARGUMENT", message: "Protocol string required", details: nil))
                }
            case "disconnect":
                self.disconnect(result: result)
            case "sendData":
                if let args = call.arguments as? [String: String], let data = args["data"] {
                    self.sendData(data: data, result: result)
                } else {
                    result(FlutterError(code: "INVALID_ARGUMENT", message: "Data required", details: nil))
                }
            default:
                result(FlutterMethodNotImplemented)
            }
        }

        // Discovered Devices Event Channel
        let discoveredDevicesEventChannel = FlutterEventChannel(
            name: discoveredDevicesChannel,
            binaryMessenger: controller.binaryMessenger
        )
        discoveredDevicesEventChannel.setStreamHandler(self)

        // Received Data Event Channel
        let receivedDataEventChannel = FlutterEventChannel(
            name: receivedDataChannel,
            binaryMessenger: controller.binaryMessenger
        )
        receivedDataEventChannel.setStreamHandler(self)

        // Register for accessory connection notifications
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

        GeneratedPluginRegistrant.register(with: self)
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    private func startScanning(result: FlutterResult) {
        print("Starting accessory scan")
        accessoryManager.registerForLocalNotifications()
        let accessories = accessoryManager.connectedAccessories
        for accessory in accessories {
            notifyAccessoryDiscovered(accessory)
        }
        result(nil)
    }

    private func stopScanning(result: FlutterResult) {
        print("Stopping accessory scan")
        accessoryManager.unregisterForLocalNotifications()
        result(nil)
    }

    private func connectToDevice(protocolString: String, uuid: String, result: FlutterResult) {
        guard let accessory = accessoryManager.connectedAccessories.first(where: {
            $0.protocolStrings.contains(protocolString)
        }) else {
            print("No accessory found with protocol: \(protocolString)")
            result(FlutterError(code: "DEVICE_NOT_FOUND", message: "No accessory with protocol \(protocolString)", details: nil))
            return
        }

        // Disconnect any existing session
        disconnectSession()

        // Create new session
        session = EASession(accessory: accessory, forProtocol: protocolString)
        guard let session = session else {
            print("Failed to create session for protocol: \(protocolString)")
            result(FlutterError(code: "SESSION_ERROR", message: "Failed to create session", details: nil))
            return
        }

        // Open input and output streams
        session.inputStream?.delegate = self
        session.inputStream?.schedule(in: .main, forMode: .default)
        session.inputStream?.open()
        session.outputStream?.schedule(in: .main, forMode: .default)
        session.outputStream?.open()

        connectedAccessory = accessory
        print("Connected to accessory: \(accessory.name)")
        result(nil)
    }

    private func disconnect(result: FlutterResult) {
        disconnectSession()
        connectedAccessory = nil
        print("Disconnected")
        result(nil)
    }

    private func sendData(data: String, result: FlutterResult) {
        guard let outputStream = session?.outputStream, outputStream.hasSpaceAvailable else {
            print("Cannot send data: no session or output stream unavailable")
            result(FlutterError(code: "NOT_CONNECTED", message: "Not connected or output stream unavailable", details: nil))
            return
        }

        let dataBytes = [UInt8](data.utf8)
        let bytesWritten = dataBytes.withUnsafeBufferPointer { buffer in
            outputStream.write(buffer.baseAddress!, maxLength: buffer.count)
        }

        if bytesWritten == dataBytes.count {
            print("Sent data: \(data)")
            result(nil)
        } else {
            print("Failed to send data")
            result(FlutterError(code: "SEND_ERROR", message: "Failed to send data", details: nil))
        }
    }

    private func disconnectSession() {
        session?.inputStream?.close()
        session?.inputStream?.remove(from: .main, forMode: .default)
        session?.inputStream?.delegate = nil
        session?.outputStream?.close()
        session?.outputStream?.remove(from: .main, forMode: .default)
        session = nil
        print("Session disconnected")
    }

    @objc private func accessoryDidConnect(notification: Notification) {
        guard let accessory = notification.userInfo?[EAAccessoryKey] as? EAAccessory else { return }
        print("Accessory connected: \(accessory.name)")
        notifyAccessoryDiscovered(accessory)
    }

    @objc private func accessoryDidDisconnect(notification: Notification) {
        guard let accessory = notification.userInfo?[EAAccessoryKey] as? EAAccessory,
              accessory.connectionID == connectedAccessory?.connectionID else { return }
        print("Accessory disconnected: \(accessory.name)")
        disconnectSession()
        connectedAccessory = nil
        receivedDataSink?(FlutterError(code: "DISCONNECTED", message: "Accessory disconnected", details: nil))
    }

    private func notifyAccessoryDiscovered(_ accessory: EAAccessory) {
        guard let sink = discoveredDevicesSink else { return }
        let deviceInfo: [String: Any] = [
            "name": accessory.name.isEmpty ? "Unknown" : accessory.name,
//            "protocol": accessory.protocolStrings.first ?? "",
//            "connectionID": accessory.connectionID,
            "address": accessory.connectionID.description,
            "uuids": accessory.protocolStrings
        ]
        print("Notifying Flutter of accessory: \(accessory.name)")
        sink(deviceInfo)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        disconnectSession()
    }
}

// MARK: - StreamHandler for Event Channels
extension AppDelegate: FlutterStreamHandler {
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        if arguments as? String == discoveredDevicesChannel {
            discoveredDevicesSink = events
        } else if arguments as? String == receivedDataChannel {
            receivedDataSink = events
        }
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        if arguments as? String == discoveredDevicesChannel {
            discoveredDevicesSink = nil
        } else if arguments as? String == receivedDataChannel {
            receivedDataSink = nil
        }
        return nil
    }
}

// MARK: - StreamDelegate for Input Stream
extension AppDelegate: StreamDelegate {
    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .hasBytesAvailable:
            guard aStream == session?.inputStream else { return }
            var buffer = [UInt8](repeating: 0, count: 1024)
            if let bytesRead = session?.inputStream?.read(&buffer, maxLength: buffer.count), bytesRead > 0 {
                let data = String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? ""
                print("Received data: \(data)")
                receivedDataSink?(data)
            }
        case .errorOccurred:
            print("Stream error occurred")
            receivedDataSink?(FlutterError(code: "STREAM_ERROR", message: "Stream error", details: nil))
        case .endEncountered:
            print("Stream ended")
            disconnectSession()
            receivedDataSink?(FlutterError(code: "STREAM_ENDED", message: "Stream ended", details: nil))
        default:
            break
        }
    }
}
