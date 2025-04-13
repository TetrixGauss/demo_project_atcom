package com.example.demo_project_atcom

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothSocket
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.UUID

class MainActivity : FlutterActivity() {
    private val TAG = "BluetoothMainActivity"
    private val METHOD_CHANNEL = "com.example/bluetooth"
    private val DISCOVERED_DEVICES_CHANNEL = "com.example/bluetooth_discovered_devices"
    private val RECEIVED_DATA_CHANNEL = "com.example/bluetooth_received_data"
    private val SPP_UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")

    private var bluetoothAdapter: BluetoothAdapter? = BluetoothAdapter.getDefaultAdapter()
    private var bluetoothSocket: BluetoothSocket? = null
    private var inputStream: InputStream? = null
    private var outputStream: OutputStream? = null
    private var readingThread: Thread? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    private var discoveredDevicesSink: EventChannel.EventSink? = null
    private var receivedDataSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startScanning" -> {
                    if (bluetoothAdapter == null || !bluetoothAdapter!!.isEnabled) {
                        Log.e(TAG, "Bluetooth not available or not enabled")
                        result.error("BLUETOOTH_NOT_AVAILABLE", "Bluetooth is not available or not enabled", null)
                    } else {
                        startScanning()
                        result.success(null)
                    }
                }
                "stopScanning" -> {
                    stopScanning()
                    result.success(null)
                }
                "connectToDevice" -> {
                    val address = call.argument<String>("address")
                    val uuid = call.argument<String>("uuid")
                    if (address != null) {
                        connectToDevice(address, uuid ?: "", result)
                    } else {
                        Log.e(TAG, "Device address missing")
                        result.error("INVALID_ARGUMENT", "Device address is required", null)
                    }
                }
                "disconnect" -> {
                    disconnect()
                    result.success(null)
                }
                "sendData" -> {
                    val data = call.argument<String>("data")
                    if (data != null) {
                        sendData(data, result)
                    } else {
                        Log.e(TAG, "Data missing")
                        result.error("INVALID_ARGUMENT", "Data is required", null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, DISCOVERED_DEVICES_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    discoveredDevicesSink = events
                }
                override fun onCancel(arguments: Any?) {
                    discoveredDevicesSink = null
                }
            }
        )

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, RECEIVED_DATA_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    receivedDataSink = events
                }
                override fun onCancel(arguments: Any?) {
                    receivedDataSink = null
                }
            }
        )
    }

    private fun startScanning() {
        Log.i(TAG, "Starting Bluetooth discovery")
        bluetoothAdapter?.cancelDiscovery()
        val filter = IntentFilter(BluetoothDevice.ACTION_FOUND).apply {
            addAction(BluetoothAdapter.ACTION_DISCOVERY_STARTED)
            addAction(BluetoothAdapter.ACTION_DISCOVERY_FINISHED)
        }
        registerReceiver(receiver, filter)
        bluetoothAdapter?.startDiscovery()
    }

    private fun stopScanning() {
        Log.i(TAG, "Stopping Bluetooth discovery")
        bluetoothAdapter?.cancelDiscovery()
        try {
            unregisterReceiver(receiver)
        } catch (e: IllegalArgumentException) {
            Log.w(TAG, "Receiver not registered")
        }
    }

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                BluetoothDevice.ACTION_FOUND -> {
                    val device: BluetoothDevice? = intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
                    device?.let {
                        val name = it.name ?: "Unknown"
                        val address = it.address
                        val uuids = it.uuids?.map { uuid -> uuid.toString() } ?: emptyList()
                        Log.i(TAG, "Found device: $name ($address)")
                        discoveredDevicesSink?.success(mapOf("name" to name, "address" to address, "uuids" to uuids))
                    }
                }
                BluetoothAdapter.ACTION_DISCOVERY_STARTED -> Log.i(TAG, "Discovery started")
                BluetoothAdapter.ACTION_DISCOVERY_FINISHED -> Log.i(TAG, "Discovery finished")
            }
        }
    }

    private fun connectToDevice(address: String, uuid: String, result: MethodChannel.Result) {
        Thread {
            try {
                val device = bluetoothAdapter?.getRemoteDevice(address)
                if (device == null) {
                    Log.e(TAG, "Device not found for address: $address")
                    mainHandler.post { result.error("DEVICE_NOT_FOUND", "Device not found", null) }
                    return@Thread
                }

                // Check bonding state
                if (device.bondState != BluetoothDevice.BOND_BONDED) {
                    Log.w(TAG, "Device not bonded: $address")
                    mainHandler.post { result.error("NOT_BONDED", "Please pair the device first", null) }
                    return@Thread
                }

                // Cancel discovery
                bluetoothAdapter?.cancelDiscovery()
                Log.i(TAG, "Discovery canceled before connecting to $address")

                // Cleanup previous socket if exists
                bluetoothSocket?.let {
                    try {
                        it.close()
                    } catch (e: IOException) {
                        Log.w(TAG, "Failed to close old socket: ${e.message}")
                    }
                }

                // Attempt connection with retry logic
                var retryCount = 0
                val maxRetries = 3
                while (retryCount < maxRetries) {
                    try {
                        Log.i(TAG, "Attempting connection (try ${retryCount + 1}) to $address")
                        bluetoothSocket = device.createRfcommSocketToServiceRecord(UUID.fromString(uuid))
                        bluetoothSocket?.connect()
                        Log.i(TAG, "Connected successfully to $address")
                        break
                    } catch (e: IOException) {
                        Log.w(TAG, "Connection attempt ${retryCount + 1} failed: ${e.message}")
                        bluetoothSocket?.close()
                        if (retryCount < maxRetries - 1) {
                            Thread.sleep(1000) // Wait 1 second before retry
                            retryCount++
                        } else {
                            // Fallback to reflection
                            try {
                                Log.i(TAG, "Trying reflection fallback for $address")
                                val method = device.javaClass.getMethod("createRfcommSocket", Int::class.java)
                                bluetoothSocket = method.invoke(device, 1) as BluetoothSocket
                                bluetoothSocket?.connect()
                                Log.i(TAG, "Connected via reflection to $address")
                                break
                            } catch (e2: Exception) {
                                Log.e(TAG, "All connection attempts failed: ${e2.message}")
                                mainHandler.post { result.error("CONNECT_ERROR", e2.message, null) }
                                return@Thread
                            }
                        }
                    }
                }

                inputStream = bluetoothSocket?.inputStream
                outputStream = bluetoothSocket?.outputStream
                startReading()
                mainHandler.post { result.success(null) }
            } catch (e: Exception) {
                Log.e(TAG, "Unexpected error during connection: ${e.message}")
                mainHandler.post { result.error("CONNECT_ERROR", e.message, null) }
            }
        }.start()
    }

    private fun disconnect() {
        Log.i(TAG, "Disconnecting Bluetooth")
        try {
            readingThread?.interrupt()
            readingThread = null
            inputStream?.close()
            outputStream?.close()
            bluetoothSocket?.close()
            bluetoothSocket = null
            Log.i(TAG, "Disconnected successfully")
        } catch (e: IOException) {
            Log.w(TAG, "Error during disconnect: ${e.message}")
        }
    }

    private fun sendData(data: String, result: MethodChannel.Result) {
        Thread {
            try {
                if (bluetoothSocket?.isConnected != true) {
                    Log.e(TAG, "Socket not connected for sending data")
                    mainHandler.post { result.error("NOT_CONNECTED", "Not connected to device", null) }
                    return@Thread
                }
                outputStream?.write(data.toByteArray())
                outputStream?.flush()
                Log.i(TAG, "Sent data: $data")
                mainHandler.post { result.success(null) }
            } catch (e: IOException) {
                Log.e(TAG, "Send data failed: ${e.message}")
                mainHandler.post { result.error("SEND_ERROR", e.message, null) }
            }
        }.start()
    }

    private fun startReading() {
        readingThread = Thread {
            val buffer = ByteArray(1024)
            var bytes: Int
            Log.i(TAG, "Starting read thread")
            while (!Thread.currentThread().isInterrupted && bluetoothSocket?.isConnected == true) {
                try {
                    bytes = inputStream?.read(buffer) ?: 0
                    if (bytes > 0 && receivedDataSink != null) {
                        val data = String(buffer, 0, bytes)
                        Log.i(TAG, "Received data: $data")
                        mainHandler.post { receivedDataSink?.success(data) }
                    }
                } catch (e: IOException) {
                    Log.w(TAG, "Read failed: ${e.message}")
                    if (!Thread.currentThread().isInterrupted) {
                        mainHandler.post { receivedDataSink?.error("READ_ERROR", e.message, null) }
                    }
                    break
                }
            }
            Log.i(TAG, "Read thread stopped")
        }
        readingThread?.start()
    }

    override fun onDestroy() {
        super.onDestroy()
        stopScanning()
        disconnect()
    }
}
