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

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

class BluetoothService extends ChangeNotifier {
  BluetoothService._internal();

  static final BluetoothService _instance = BluetoothService._internal();

  static BluetoothService get instance => _instance;

  ValueNotifier<Device?> deviceBondedNotifier = ValueNotifier<Device?>(null);

  static const MethodChannel _methodChannel = MethodChannel('com.example/bluetooth');
  static const EventChannel _discoveredDevicesChannel = EventChannel('com.example/bluetooth_discovered_devices');
  static const EventChannel _receivedDataChannel = EventChannel('com.example/bluetooth_received_data');
  static const EventChannel _pairingStateChannel = EventChannel('com.example/bluetooth_pairing_state');
  static const EventChannel _pairedDevicesChannel = EventChannel('com.example/bluetooth_paired_devices');

  void setBondedDevice(Device device) {
    deviceBondedNotifier.value = device;
    notifyListeners();
  }

  Future<void> requestBluetoothPermissions() async {
    if (await Permission.bluetooth.isGranted && await Permission.bluetoothScan.isGranted && await Permission.bluetoothConnect.isGranted) {
      print("Bluetooth permissions already granted.");
      return;
    }

    Map<Permission, PermissionStatus> statuses = await [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse, // For scanning on older Android versions
    ].request();

    statuses.forEach((permission, status) {
      if (status.isGranted) {
        print("$permission granted.");
      } else {
        print("$permission denied.");
      }
    });
  }

  Future<void> startScanning({int? timeout}) async {
    await _methodChannel.invokeMethod('startScanning', {'timeout': timeout});
  }

  Future<void> stopScanning() async {
    await _methodChannel.invokeMethod('stopScanning');
  }

  Future<void> rescan({int? timeoutSeconds}) async {
    try {
      await stopScanning();
      await Future.delayed(Duration(milliseconds: 500)); // Prevent race condition
      await startScanning(timeout: timeoutSeconds);
      print("Rescan initiated");
    } catch (e) {
      print("Rescan failed: $e");
    }
  }

  Future<void> pairDevice(String address) async {
    try {
      final result = await _methodChannel.invokeMethod('pairDevice', {'address': address});
      print(result);
    } on PlatformException catch (e) {
      print("Failed to pair: ${e.message}");
    }
  }

  Stream<Map<String, dynamic>> get pairingStateStream =>
      _pairingStateChannel.receiveBroadcastStream().map((event) => Map<String, dynamic>.from(event));

  Future<void> connectToDevice(String address, String uuid) async {
    await _methodChannel.invokeMethod('connectToDevice', {'address': address, 'uuid': uuid});
  }

  Future<void> disconnect() async {
    await _methodChannel.invokeMethod('disconnect');
  }

  Future<void> sendData(String address, String data) async {
    await _methodChannel.invokeMethod('sendData', {'address': address, 'data': data});
  }

  Future<Map<String, dynamic>?> checkPrinterStatus() async {
    try {
      final result = await _methodChannel.invokeMethod('checkStatus');
      return Map<String, dynamic>.from(result);
    } on PlatformException catch (e) {
      print('Status check failed: ${e.message}');
      return null;
    }
  }

  Stream<String> get receivedDataStream => _receivedDataChannel.receiveBroadcastStream().map((event) => event.toString());

  Stream<List<Device>> get discoveredDevicesStream {
    List<Device> devices = [];
    return _discoveredDevicesChannel.receiveBroadcastStream().map((device) {
      if (device.containsKey('event') && device['event'] == 'timeout') {
        print('Scan timeout: ${device['message']}');
      } else {
        print("Discovered device: ${device['name']} - ${device['address']} - ${device['type']}");
        final newDevice = Device(
          name: device['name'] ?? "",
          address: device['address'] ?? "",
          uuids: device['uuids'] as List<dynamic>? ?? [],
          type: device['type'] ?? "",
        );
        if (!devices.any((d) => d.address == newDevice.address)) {
          devices.add(newDevice);
        }
      }
      return devices;
    });

  }

  Stream<List<Device>> get pairedDevicesStream {
    List<Device> devices = [];
    return _pairedDevicesChannel.receiveBroadcastStream().map((device) {
    if (device.containsKey('event') && device['event'] == 'timeout') {
      print('Scan timeout: ${device['message']}');
    } else {
      print("Discovered device: ${device['name']} - ${device['address']} - ${device['type']}");
      final Device newDevice = Device(
        name: device['name'] ?? "",
        address: device['address'] ?? "",
        uuids: device['uuids'] as List<dynamic>? ?? [],
        type: device['type'] ?? "",
      );
      if (!devices.any((d) => d.address == newDevice.address)) {
        devices.add(newDevice);
      }
    }
    return devices;
  });
  }

}

class Device {
  final String name;
  final String address;
  final List<dynamic> uuids;
  final String? type;

  Device({required this.name, required this.address, required this.uuids, this.type});

  @override
  String toString() {
    return 'Device{name: $name, address: $address, type: $type} ' ;
  }
}
