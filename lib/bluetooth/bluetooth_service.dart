// import 'dart:async';
//
// import 'package:flutter/foundation.dart';
// import 'package:flutter_blue_classic/flutter_blue_classic.dart';
//
// class BluetoothService with ChangeNotifier {
//   BluetoothService._internal();
//
//   static final BluetoothService _instance = BluetoothService._internal();
//
//   static BluetoothService get instance => _instance;
//
//   final FlutterBlueClassic flutterBlueClassicPlugin = FlutterBlueClassic();
//
//   StreamController<List<BluetoothDevice>>? _devicesStreamController;
//
//   Stream<List<BluetoothDevice>>? get devicesStream => _devicesStreamController?.stream;
//
//   ValueNotifier<BluetoothAdapterState> adapterStateNotifier = ValueNotifier<BluetoothAdapterState>(BluetoothAdapterState.unknown);
//
//   StreamSubscription? adapterStateSubscription;
//
//   void setAdapterState(BluetoothAdapterState state) {
//     adapterStateNotifier.value = state;
//     notifyListeners();
//   }
//
//   Future<void> initPlatformState() async {
//     try {
//       setAdapterState(await flutterBlueClassicPlugin.adapterStateNow);
//     } catch (e) {
//       if (kDebugMode) print(e);
//     }
//   }
//
//   Future<void> startDeviceDiscovery() async {
//     List<BluetoothDevice> discoveredDevices = <BluetoothDevice>[];
//     _devicesStreamController = StreamController<List<BluetoothDevice>>.broadcast();
//     flutterBlueClassicPlugin.scanResults.listen(
//       (device) {
//         discoveredDevices = [...discoveredDevices, device];
//
//         _devicesStreamController?.sink.add(discoveredDevices);
//         print("Discovered device: ${device.name} - ${device.address}");
//       },
//       onError: (error) {
//         print("Error discovering devices: $error");
//       },
//     );
//     flutterBlueClassicPlugin.startScan();
//   }
//
//   Future<void> stopDeviceDiscovery() async {
//     flutterBlueClassicPlugin.stopScan();
//     _devicesStreamController?.sink.close();
//     await _devicesStreamController?.close();
//   }
//
//   Future<BluetoothConnection?> connectToDevice({required BluetoothDevice device}) async {
//     // try {
//     await flutterBlueClassicPlugin.bondDevice(device.address);
//     BluetoothConnection? connection = await flutterBlueClassicPlugin.connect(device.address);
//     await Future.delayed(Duration(seconds: 1));
//     if (connection == null || !connection.isConnected) {
//       print("Failed to connect to device: ${device.name} - ${device.address}");
//       return null;
//     }
//     print("Connected to device: ${device.name} - ${device.address}");
//
//     return connection;
//     // } catch (e) {
//     //   print("Error connecting to device: $e");
//     //   return null;
//     // }
//   }
//   //
//   // void discoverServices(Device device) async {
//   //   // Connect to the device
//   //   BluetoothClassic().
//   //
//   //   // Discover services
//   //   List<BluetoothService> services = await device.discoverServices();
//   //   for (BluetoothService service in services) {
//   //     print('Service UUID: ${service.uuid}');
//   //     for (BluetoothCharacteristic characteristic in service.characteristics) {
//   //       print('Characteristic UUID: ${characteristic.uuid}');
//   //     }
//   //   }
//   //
//   //   // Disconnect after discovery
//   //   await device.disconnect();
//   // }
//
//   void startScan() {
//     flutterBlueClassicPlugin.startScan();
//   }
//
//   void stopScan() {
//     flutterBlueClassicPlugin.stopScan();
//   }
// }
import 'dart:async';

import 'package:flutter/services.dart';

class BluetoothService {
  BluetoothService._internal();

  static final BluetoothService _instance = BluetoothService._internal();

  static BluetoothService get instance => _instance;

  StreamController<List<Device>>? _devicesStreamController;

  Stream<List<Device>>? get devicesStream => _devicesStreamController?.stream;

  static const MethodChannel _methodChannel = MethodChannel('com.example/bluetooth');
  static const EventChannel _discoveredDevicesChannel = EventChannel('com.example/bluetooth_discovered_devices');
  static const EventChannel _receivedDataChannel = EventChannel('com.example/bluetooth_received_data');

  Future<void> startScanning() async {
    await _methodChannel.invokeMethod('startScanning');
    discoveredDevicesStream();
  }

  Future<void> stopScanning() async {
    await _methodChannel.invokeMethod('stopScanning');
  }

  Future<void> connectToDevice(String address, String uuid) async {
    await _methodChannel.invokeMethod('connectToDevice', {'address': address, 'uuid': uuid});
  }

  Future<void> disconnect() async {
    await _methodChannel.invokeMethod('disconnect');
  }

  Future<void> sendData(String data) async {
    await _methodChannel.invokeMethod('sendData', {'data': data});
  }

  void discoveredDevicesStream() {
    List<Device> devices = [];
    _devicesStreamController = StreamController<List<Device>>.broadcast();
    _discoveredDevicesChannel.receiveBroadcastStream().map((event) => Map<String, dynamic>.from(event)).listen(
      (device) {
        devices.add(Device(name: device['name'] ?? "", address: device['address'] ?? "", uuids: device['uuids'] as List<dynamic>? ?? []));
        _devicesStreamController?.sink.add(devices);
      },
    );
  }

  Stream<String> get receivedDataStream => _receivedDataChannel.receiveBroadcastStream().map((event) => event.toString());
}

class Device {
  final String name;
  final String address;
  final List<dynamic> uuids;

  Device({required this.name, required this.address, required this.uuids});

  @override
  String toString() {
    return 'Device{name: $name, address: $address} ';
  }
}
