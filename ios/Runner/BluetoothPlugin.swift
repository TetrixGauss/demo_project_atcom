import Flutter
import Foundation

public class BluetoothPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private var bleManager: BluetoothLeManager?
    private var classicManager: BluetoothClassicManager?
    private var discoveredSink: FlutterEventSink?
    private var receivedDataSink: FlutterEventSink?
    private var pairingStateSink: FlutterEventSink?
    private var pairedDevicesSink: FlutterEventSink?
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = BluetoothPlugin()
        
        let methodChannel = FlutterMethodChannel(name: "com.example/bluetooth", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: methodChannel)
        
        let discoveredChannel = FlutterEventChannel(name: "com.example/bluetooth_discovered_devices", binaryMessenger: registrar.messenger())
        discoveredChannel.setStreamHandler(instance)
        
        let receivedDataChannel = FlutterEventChannel(name: "com.example/bluetooth_received_data", binaryMessenger: registrar.messenger())
        receivedDataChannel.setStreamHandler(instance)
        
        let pairingStateChannel = FlutterEventChannel(name: "com.example/bluetooth_pairing_state", binaryMessenger: registrar.messenger())
        pairingStateChannel.setStreamHandler(instance)
        
        let pairedDevicesChannel = FlutterEventChannel(name: "com.example/bluetooth_paired_devices", binaryMessenger: registrar.messenger())
        pairedDevicesChannel.setStreamHandler(instance)
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let arguments = call.arguments as? [String: Any]
        let isBLE = arguments?["isBLE"] as? Bool ?? false
        
        switch call.method {
        case "startScanning":
            let timeout = arguments?["timeout"] as? Int
            if isBLE {
                bleManager?.startScanning(timeoutSeconds: timeout, result: result)
            } else {
                classicManager?.startScanning(timeoutSeconds: timeout, result: result)
            }
        case "stopScanning":
            bleManager?.stopScanning(result: { _ in
                self.classicManager?.stopScanning(result: result)
            })
        case "pairDevice":
            result(FlutterError(code: "NOT_SUPPORTED", message: "Pairing not supported on iOS", details: nil))
        case "connectToDevice":
            let address = arguments?["address"] as? String
            if isBLE, let address = address {
                bleManager?.connectToDevice(address: address, result: result)
            } else if let address = address {
                classicManager?.connectToDevice(address: address, result: result)
            } else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "Device address is required", details: nil))
            }
        case "disconnect":
            bleManager?.disconnect(result: { _ in
                self.classicManager?.disconnect(result: result)
            })
        case "sendData":
            let data = arguments?["data"] as? String
            if isBLE, let data = data {
                bleManager?.sendData(data: data, result: result)
            } else if let data = data {
                classicManager?.sendReceipt(data: data, result: result)
            } else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "Data is required", details: nil))
            }
        case "checkStatus":
            if isBLE {
                bleManager?.checkStatus(result: result)
            } else {
                classicManager?.checkStatus(result: result)
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        if let channelName = (arguments as? [String: Any])?["channel"] as? String {
            switch channelName {
            case "com.example/bluetooth_discovered_devices":
                discoveredSink = events
            case "com.example/bluetooth_received_data":
                receivedDataSink = events
            case "com.example/bluetooth_pairing_state":
                pairingStateSink = events
            case "com.example/bluetooth_paired_devices":
                pairedDevicesSink = events
                sendPairedDevices()
            default:
                return FlutterError(code: "INVALID_CHANNEL", message: "Unknown channel", details: nil)
            }
        }
        return nil
    }
    
    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        if let channelName = (arguments as? [String: Any])?["channel"] as? String {
            switch channelName {
            case "com.example/bluetooth_discovered_devices":
                discoveredSink = nil
            case "com.example/bluetooth_received_data":
                receivedDataSink = nil
            case "com.example/bluetooth_pairing_state":
                pairingStateSink = nil
            case "com.example/bluetooth_paired_devices":
                pairedDevicesSink = nil
            default:
                return FlutterError(code: "INVALID_CHANNEL", message: "Unknown channel", details: nil)
            }
        }
        return nil
    }
    
    override init() {
        super.init()
        bleManager = BluetoothLeManager { [weak self] event in
            self?.handleBluetoothEvent(event)
        }
        classicManager = BluetoothClassicManager(protocolString: "com.epson.printer") { [weak self] event in
            self?.handleBluetoothEvent(event)
        }
    }
    
    private func handleBluetoothEvent(_ event: BluetoothEvent) {
        switch event {
        case .DiscoveredDevice(let device):
            print("Streaming discovered device: \(device.toDictionary())")
            discoveredSink?(device.toDictionary())
        case .ReceivedData(let data):
            print("Streaming received data: \(data)")
            receivedDataSink?(data)
        case .Error(let code, let message):
            print("Streaming error: \(code) - \(message ?? "No message")")
            discoveredSink?(["event": "error", "code": code, "message": message ?? ""])
        }
    }
    
    private func sendPairedDevices() {
        let bleDevices = bleManager?.getPairedDevices() ?? []
        let classicDevices = classicManager?.getPairedDevices() ?? []
        let allDevices = (bleDevices + classicDevices).distinct(by: { $0["address"] as? String })
        allDevices.forEach { device in
            print("Streaming paired device: \(device)")
            pairedDevicesSink?(device)
        }
    }
    
    deinit {
        bleManager?.cleanup()
        classicManager?.cleanup()
    }
}

// Extension to mimic Kotlin's distinctBy
extension Array {
    func distinct(by key: (Element) -> Any?) -> [Element] {
        var seen = Set<AnyHashable>()
        return filter { element in
            guard let keyValue = key(element) as? AnyHashable else { return false }
            return seen.insert(keyValue).inserted
        }
    }
}
