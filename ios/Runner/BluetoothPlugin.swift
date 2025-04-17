import Flutter
import UIKit
import ExternalAccessory
import CoreBluetooth

public class BluetoothPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private var bleManager: BluetoothLeManager?
    private var classicManager: BluetoothClassicManager?
    private var discoveredSink: FlutterEventSink?
    private var pairedSink: FlutterEventSink?
    private var discoveredPendingEvents: [BluetoothEvent] = []
    private var pairedPendingEvents: [BluetoothEvent] = []

    override init() {
        super.init()
        bleManager = BluetoothLeManager { [weak self] event in
            self?.handleBluetoothEvent(event, isPaired: false)
        }
        classicManager = BluetoothClassicManager { [weak self] event in
            self?.handleBluetoothEvent(event, isPaired: true)
        }
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "com.example/bluetooth", binaryMessenger: registrar.messenger())
        let discoveredChannel = FlutterEventChannel(name: "com.example/bluetooth_discovered_devices", binaryMessenger: registrar.messenger())
        let instance = BluetoothPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
        discoveredChannel.setStreamHandler(instance)
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
                classicManager?.startScanning(result: result)
            }

        case "stopScanning":
            if isBLE {
                bleManager?.stopScanning(result: result)
            } else {
                classicManager?.stopScanning(result: result)
            }

        case "pairDevice":
            let deviceName = arguments?["deviceName"] as? String ?? ""
            if isBLE {
                result(FlutterError(code: "NOT_SUPPORTED", message: "Pairing not supported for BLE", details: nil))
            } else {
                classicManager?.pairDevice(deviceName: deviceName, result: result)
            }

        case "getPairedDevices":
            if isBLE {
                result([]) // BLE paired devices not implemented
            } else {
                let pairedDevices = classicManager?.getPairedDevices() ?? []
                result(pairedDevices)
            }

        case "connectToDevice":
            let address = arguments?["address"] as? String ?? ""
            if isBLE {
                bleManager?.connectToDevice(address: address, result: result)
            } else {
                classicManager?.connectToDevice(address: address, result: result)
            }

        case "disconnect":
            if isBLE {
                bleManager?.disconnect(result: result)
            } else {
                classicManager?.disconnect(result: result)
            }

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

        case "checkBluetoothState":
            let state = bleManager?.getBluetoothState() ?? .unknown
            result(state == .poweredOn ? "poweredOn" : "poweredOff")

        case "checkLocationState":
            result("authorizedWhenInUse") // Simplified for demo

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        let channel = arguments as? String ?? ""
        print("onListen called for \(channel) with arguments: \(String(describing: arguments))")
        if channel == "com.example/bluetooth_discovered_devices" {
            discoveredSink = events
            print("Discovered sink set, processing \(discoveredPendingEvents.count) queued events")
            let eventsToProcess = discoveredPendingEvents
            discoveredPendingEvents.removeAll()
            for event in eventsToProcess {
                if case .discoveredDevice(let device) = event {
                    print("Sending queued discovered device: \(device.name) (\(device.address)), isBLE: \(device.isBle)")
                    events(device.toDictionary())
                }
            }
        } else if channel == "com.example/bluetooth_paired_devices" {
            pairedSink = events
            print("Paired sink set, streaming paired devices and processing \(pairedPendingEvents.count) queued events")
            if let pairedDevices = classicManager?.getPairedDevices() {
                for device in pairedDevices {
                    let pairedDevice = BluetoothEvent.DiscoveredDevice(
                        name: device["name"] as? String ?? "Unknown",
                        address: device["address"] as? String ?? "Unknown",
                        uuids: device["uuids"] as? [String] ?? [],
                        type: "Classic",
                        isBle: false,
                        event: "paired",
                        message: nil
                    )
                    print("Streaming paired device: \(pairedDevice.name) (\(pairedDevice.address))")
                    events(pairedDevice.toDictionary())
                }
            }
            let eventsToProcess = pairedPendingEvents
            pairedPendingEvents.removeAll()
            for event in eventsToProcess {
                if case .pairedDevice(let device) = event {
                    print("Sending queued paired device: \(device.name) (\(device.address)), isBLE: \(device.isBle)")
                    events(device.toDictionary())
                }
            }
        }
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        let channel = arguments as? String ?? ""
        print("onCancel called for \(channel)")
        if channel == "com.example/bluetooth_discovered_devices" {
            discoveredSink = nil
        } else if channel == "com.example/bluetooth_paired_devices" {
            pairedSink = nil
        }
        return nil
    }

    func handleBluetoothEvent(_ event: BluetoothEvent, isPaired: Bool) {
        switch event {
        case .discoveredDevice(let device):

            print("Sending device to discovered sink: \(device.name)")
            if let sink = discoveredSink {
                sink(device.toDictionary())
            } else {
                print("Discovered sink is nil, unable to send device")
                discoveredPendingEvents.append(event)
            }

        case .pairedDevice(let device):

            print("Sending device to paired sink: \(device.name)")
            if let sink = pairedSink {
                sink(device.toDictionary())
            } else {
                print("Discovered sink is nil, unable to send device")
                pairedPendingEvents.append(event)
            }


        case .receivedData(let data):
            print("Received data: \(data.data)")
            let sink = isPaired ? pairedSink : discoveredSink
            if let sink = sink {
                print("Sending received data to \(isPaired ? "paired" : "discovered") sink")
                sink(data.data)
            } else {
                print("\(isPaired ? "Paired" : "Discovered") sink is nil, ignoring received data")
            }
        case .error(let error):
            print("Error occurred: \(error.code), message: \(String(describing: error.message))")
            let sink = isPaired ? pairedSink : discoveredSink
            if let sink = sink {
                print("Sending error to \(isPaired ? "paired" : "discovered") sink")
                sink(FlutterError(code: error.code, message: error.message, details: nil))
            } else {
                print("\(isPaired ? "Paired" : "Discovered") sink is nil, ignoring error")
            }
        default:
            print("Unknown event type")
        }

    }
}
