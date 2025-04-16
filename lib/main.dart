import 'package:demo_project_atcom/bluetooth/bluetooth_service.dart';
import 'package:flutter/material.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await BluetoothService.instance.requestBluetoothPermissions();
  // await BluetoothService.initBluetooth();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const MyHomePage(title: 'Flutter Demo Home Page'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  int _counter = 0;

  Future<void> _incrementCounter() async {
    BluetoothService.instance.startScanning();
    showDialog(
        barrierDismissible: false,
        context: context,
        builder: (_) {
          return AlertDialog(
            title: Text("Bluetooth"),
            content: SizedBox(
              width: double.minPositive,
              child: StreamBuilder<List<Device>>(
                  stream: BluetoothService.instance.discoveredDevicesStream,
                  builder: (ctx, snapshot) {

                    final devices = snapshot.data ?? [];
                    if (devices.isEmpty) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      if (snapshot.hasError) {
                        return Text("Error: ${snapshot.error}");
                      }
                      return const Text("No devices discovered");
                    } else {
                      final List<Device> devices = snapshot.data!;
                      print("Devices: $devices");
                      return ListView.builder(
                        shrinkWrap: true,
                        itemBuilder: (_, index) {
                          Device device = devices[index];
                          return ListTile(
                            title: Text("Device ${device.name} - ${device.address} - ${device.type}"),
                            onTap: () async {
                              await BluetoothService.instance.pairDevice(device.address);
                              print("Device tapped: ${device.name}");
                              print("Device address: ${device.address}");
                              print("Device UUIDs: ${device.uuids}");
                              // Print the UUIDs of the device
                              BluetoothService.instance.setBondedDevice(device);
                              BluetoothService.instance.stopScanning();
                              Navigator.pop(context);
                            },
                          );
                        },
                        itemCount: devices.length, // Replace with actual device count
                      );
                    }
                  }),
            ),
            actions: [
              TextButton(
                onPressed: () async {
                  await BluetoothService.instance.stopScanning();
                  Navigator.pop(context);
                },
                child: const Text("Close"),
              ),
              TextButton(
                onPressed: () async {
                  await BluetoothService.instance.stopScanning();
                  await BluetoothService.instance.startScanning();
                },
                child: const Text("ReScan"),
              ),
            ],
          );
        });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Text(
              'You have pushed the button this many times:',
            ),
            Text(
              '$_counter',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            StreamBuilder(
                stream: BluetoothService.instance.pairingStateStream,
                builder: (context, snapshot) {
                  if(!snapshot.hasData) {

                  }
                  return Flexible(child: Text(snapshot.data.toString()));
                }),
            ValueListenableBuilder(valueListenable: BluetoothService.instance.deviceBondedNotifier, builder: (_, value, __) {
              if(value != null) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Flexible(child: Text("Device Bonded: ${value.name} - ${value.address} - ${value.type}")),
                    TextButton(
                      onPressed: () async {
                        value.uuids.forEach((element) {
                          print("UUID: $element");
                        });
                        // Connect to the device using the first UUID
                        if(value.uuids.isEmpty) {
                          await BluetoothService.instance.connectToDevice(value.address, "");
                        } else {
                          await BluetoothService.instance.connectToDevice(value.address, value.uuids.first);
                        }
                      },
                      child: Text("Connect"),
                    ),
                    TextButton(
                      onPressed: () async {
                        value.uuids.forEach((element) {
                          print("UUID: $element");
                        });
                        await BluetoothService.instance.sendData(value.address, "Hello from Flutter ${DateTime.now()}");
                        await BluetoothService.instance.sendData(value.address, "Nikooooooooo");
                      },
                      child: Text("Send Data"),
                    ),
                  ],
                );
              }
              return const SizedBox.shrink();

            }),
            StreamBuilder(
                stream: BluetoothService.instance.receivedDataStream,
                builder: (context, snapshot) {
                  return Flexible(child: Text(snapshot.data.toString()));
                }),

            StreamBuilder<List<Device>>(
                stream: BluetoothService.instance.pairedDevicesStream,
                builder: (context, snapshot) {
                  final devices = snapshot.data ?? [];
                  if (devices.isEmpty) {
                    return const Text("No devices paired");
                  } else {
                    final List<Device> devices = snapshot.data!;
                    print("Devices: $devices");
                    return ListView.builder(
                      shrinkWrap: true,
                      itemBuilder: (_, index) {
                        Device device = devices[index];
                        return ListTile(
                          title: Text("Device ${device.name} - ${device.address} - ${device.type}"),
                          onTap: () async {
                            await BluetoothService.instance.connectToDevice(device.address, "");
                          },
                        );
                      },
                      itemCount: devices.length, // Replace with actual device count
                    );
                  }
                }),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _incrementCounter,
        tooltip: 'Increment',
        child: const Icon(Icons.add),
      ), // This trailing comma makes auto-formatting nicer for build methods.
    );
  }
}
