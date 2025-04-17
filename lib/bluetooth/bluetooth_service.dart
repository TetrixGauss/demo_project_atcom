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
import 'dart:io';

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

  Future<bool> requestPermissions() async {
    try {
      Map<Permission, PermissionStatus> statuses = await [
        Permission.bluetooth,
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
        Permission.location,
        Permission.locationAlways,
      ].request();
      bool bluetoothOk = statuses[Permission.bluetooth]!.isGranted ||
          statuses[Permission.bluetoothScan]!.isGranted ||
          statuses[Permission.bluetoothConnect]!.isGranted;
      bool locationOk = statuses[Permission.locationWhenInUse]!.isGranted ||
          statuses[Permission.locationAlways]!.isGranted ||
          statuses[Permission.location]!.isGranted;
      if(Platform.isIOS) {
        print('Not all permissions granted, checking native Bluetooth state');
        bluetoothOk = await checkNativeBluetoothState();
        print('Not all permissions granted, checking native Location state');
        locationOk = await checkNativeLocationState();
      }
      statuses.forEach((permission, status) async {
        print('${permission.toString()}: ${status.toString()}');
        if (status.isPermanentlyDenied && (bluetoothOk && locationOk)) {
          print('Permanently denied, open settings');
          await openAppSettings();
        }
      });
      // Check if all permissions are granted
      bool allGranted = statuses.values.every((status) => status.isGranted);
      if (!allGranted) {
        if(Platform.isIOS) {
          return bluetoothOk && locationOk;
        } else {
          return false;
        }
      }

      print('All permissions granted');
      return true;
    } catch (e) {
      print('Error: $e');
      return false;
    }
  }

  Future<bool> checkNativeBluetoothState() async {
    try {
      final result = await _methodChannel.invokeMethod('checkBluetoothState');
      print('Native Bluetooth state: $result');
      return result == 'poweredOn';
    } on PlatformException catch (e) {
      print('Failed to check native Bluetooth state: ${e.message}');
      return false;
    }
  }

  Future<bool> checkNativeLocationState() async {
    try {
      final result = await _methodChannel.invokeMethod('checkLocationState');
      print('Manual location state check: $result');
      return result == 'poweredOn';
    } on PlatformException catch (e) {
      print('Failed to check native Location state: ${e.message}');
      return false;
    }
  }

  Future<void> startScanning({bool? isBLE, int? timeout}) async {
    await _methodChannel.invokeMethod('startScanning', {'isBLE': isBLE ?? false, 'timeout': timeout});
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

  Future<void> pairDevice(Device device) async {
    // if(!Platform.isIOS) {
      try {
        final result;
        if(Platform.isIOS) {
          result = await _methodChannel.invokeMethod('pairDevice', {'deviceName': device.name});
        } else {
          result = await _methodChannel.invokeMethod('pairDevice', {'address': device.address});
        }
        print(result);
      } on PlatformException catch (e) {
        print("Failed to pair: ${e.message}");
      }
    // } else {
    //   print("Pairing is not supported on iOS");
    // }

  }

  Stream<Map<String, dynamic>> get pairingStateStream =>
      _pairingStateChannel.receiveBroadcastStream('com.example/bluetooth_pairing_state').map((event) => Map<String, dynamic>.from(event));

  Future<void> connectToDevice(bool? isBLE, String address, String uuid) async {
    await _methodChannel.invokeMethod('connectToDevice', {'address': address, 'uuid': uuid, 'isBLE': isBLE ?? false});
  }

  Future<void> disconnect() async {
    await _methodChannel.invokeMethod('disconnect');
  }

  Future<void> sendData(String address, String data, {bool? isBle}) async {
    await _methodChannel.invokeMethod('sendData', {'address': address, 'data': data, 'isBle': isBle ?? false});
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
    return _discoveredDevicesChannel.receiveBroadcastStream('com.example/bluetooth_discovered_devices').map((device) {
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
    return _pairedDevicesChannel.receiveBroadcastStream('com.example/bluetooth_paired_devices').map((device) {
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
    return 'Device{name: $name, address: $address, type: $type} ';
  }
}
