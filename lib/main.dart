import 'package:demo_project_atcom/bluetooth/bluetooth_service.dart';
import 'package:flutter/material.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
        context: context,
        builder: (_) {
          return AlertDialog(
            title: Text("Bluetooth"),
            content: SizedBox(
              width: double.minPositive,
              child: StreamBuilder<List<Device>>(
                  stream: BluetoothService.instance.devicesStream,
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) {
                      return const Text("No devices discovered");
                    } else {
                      final List<Device> devices = snapshot.data!;
                      print("Devices: $devices");
                      return ListView.builder(
                        shrinkWrap: true,
                        itemBuilder: (_, index) {
                          Device device = devices[index];
                          return ListTile(
                            title: Text("Device ${device.name} - ${device.address}"),
                            onTap: () async {
                              print("Device tapped: ${device.name}");
                              device.uuids.forEach((element) {
                                print("UUID: $element");
                              });

                              await BluetoothService.instance.connectToDevice(device.address, device.uuids.first);

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
                onPressed: () {
                  Navigator.pop(context);
                },
                child: const Text("Close"),
              ),
              TextButton(
                onPressed: () async {
                  await BluetoothService.instance.stopScanning();
                },
                child: const Text("ReScan"),
              ),
            ],
          );
        }).then((_) async {
      await BluetoothService.instance.stopScanning();
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
                stream: BluetoothService.instance.receivedDataStream,
                builder: (context, snapshot) {
                  return Flexible(child: Text(snapshot.data.toString()));
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
