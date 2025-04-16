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
import android.os.Parcelable
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
    private val PAIRING_STATE_CHANNEL = "com.example/bluetooth_pairing_state"
    private val PAIRED_DEVICES_CHANNEL = "com.example/bluetooth_paired_devices"
    private val SPP_UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")

    private var bluetoothAdapter: BluetoothAdapter? = BluetoothAdapter.getDefaultAdapter()
    private var bluetoothSocket: BluetoothSocket? = null
    private var inputStream: InputStream? = null
    private var outputStream: OutputStream? = null
    private var readingThread: Thread? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var discoveryTimeoutRunnable: Runnable? = null

    private var discoveredDevicesSink: EventChannel.EventSink? = null
    private var receivedDataSink: EventChannel.EventSink? = null
    private var pairingStateSink: EventChannel.EventSink? = null
    private var pairedDevicesSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startScanning" -> {
                    if (bluetoothAdapter == null || !bluetoothAdapter!!.isEnabled) {
                        Log.e(TAG, "Bluetooth not available or not enabled")
                        result.error("BLUETOOTH_NOT_AVAILABLE", "Bluetooth is not available or not enabled", null)
                    } else {
                        val timeout = call.argument<Int>("timeout")
                        startScanning(timeout)
                        result.success(null)
                    }
                }
                "stopScanning" -> {
                    stopScanning()
                    result.success(null)
                }
                "getPairedDevices" -> {
                    getPairedDevices(result)
                }
                "connectToDevice" -> {
                    val address = call.argument<String>("address")
                    val uuid = call.argument<String>("uuid")
                    if (address != null) {
                        connectToDevice(address, uuid, result)
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
                    val address = call.argument<String>("address")
                    if (data != null && address != null) {
                        sendReceipt(address, data, result)
                    } else {
                        Log.e(TAG, "Data missing")
                        result.error("INVALID_ARGUMENT", "Data is required", null)
                    }
                }
                "checkStatus" -> checkPrinterStatus(result)
                "pairDevice" -> {
                    val address = call.argument<String>("address")
                    if (address != null) {
                        pairDevice(address, result)
                    } else {
                        Log.e(TAG, "Device address missing")
                        result.error("INVALID_ARGUMENT", "Device address is required", null)
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
                override fun onCancel(arguments: Any?)  {
                    receivedDataSink = null
                }
            }
        )

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, PAIRING_STATE_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    pairingStateSink = events
                }
                override fun onCancel(arguments: Any?) {
                    pairingStateSink = null
                }
            }
        )

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, PAIRED_DEVICES_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    pairedDevicesSink = events
                    // Emit initial paired devices
                    emitPairedDevices()
                }
                override fun onCancel(arguments: Any?) {
                    pairedDevicesSink = null
                }
            }
        )

        // Register bond receiver for pairing state changes
        val bondFilter = IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED)
        registerReceiver(bondReceiver, bondFilter)
    }

    private fun startScanning(timeoutSeconds: Int? = null) {
        Log.i(TAG, "Starting Bluetooth discovery")
        if (bluetoothAdapter?.isDiscovering == true) {
            bluetoothAdapter?.cancelDiscovery()
            Log.i(TAG, "Canceled existing discovery before starting new scan")
        }
        discoveryTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
        discoveryTimeoutRunnable = null
        val filter = IntentFilter().apply {
            addAction(BluetoothDevice.ACTION_FOUND)
            addAction(BluetoothAdapter.ACTION_DISCOVERY_STARTED)
            addAction(BluetoothAdapter.ACTION_DISCOVERY_FINISHED)
            addAction(BluetoothDevice.ACTION_UUID)
        }

        try {
            registerReceiver(receiver, filter)
            Log.i(TAG, "Receiver registered for discovery")
        } catch (e: IllegalArgumentException) {
            Log.w(TAG, "Receiver already registered or error: ${e.message}")
        }

        if (bluetoothAdapter?.startDiscovery() == true) {
            Log.i(TAG, "Discovery started successfully")
        } else {
            Log.e(TAG, "Failed to start discovery")
            discoveredDevicesSink?.error("DISCOVERY_ERROR", "Failed to start discovery", null)
        }

        // Set timeout if provided and valid
        if (timeoutSeconds != null && timeoutSeconds > 0) {
            discoveryTimeoutRunnable = Runnable {
                if (bluetoothAdapter?.isDiscovering == true) {
                    bluetoothAdapter?.cancelDiscovery()
                    Log.i(TAG, "Discovery stopped due to timeout")
                    discoveredDevicesSink?.success(
                        mapOf(
                            "event" to "timeout",
                            "message" to "Discovery stopped after $timeoutSeconds seconds"
                        )
                    )
                }
            }
            mainHandler.postDelayed(discoveryTimeoutRunnable!!, timeoutSeconds * 1000L)
        }
    }

    private fun stopScanning() {
        Log.i(TAG, "Stopping Bluetooth discovery")
        // Clear timeout
        discoveryTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
        discoveryTimeoutRunnable = null

        // Stop discovery
        if (bluetoothAdapter?.isDiscovering == true) {
            bluetoothAdapter?.cancelDiscovery()
            Log.i(TAG, "Discovery canceled")
        }

        // Unregister receiver
        try {
            unregisterReceiver(receiver)
            Log.i(TAG, "Receiver unregistered")
        } catch (e: IllegalArgumentException) {
            Log.w(TAG, "Receiver not registered: ${e.message}")
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
                        val type = it.type ?: BluetoothDevice.DEVICE_TYPE_UNKNOWN
                        val uuids = it.uuids?.map { it.uuid.toString() } ?: emptyList()
                        Log.i(TAG, "Found device: $name ($address)")
                        // Start fetching UUIDs
//                        it.fetchUuidsWithSdp()
                        // Send initial device info
                        discoveredDevicesSink?.success(mapOf("name" to name, "address" to address, "uuids" to uuids, "type" to type.toString()))
                    }
                }
                BluetoothDevice.ACTION_UUID -> {
                    val device: BluetoothDevice? = intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
                    val uuids: Array<out Parcelable>? = intent.getParcelableArrayExtra(BluetoothDevice.EXTRA_UUID)
                    device?.let {
                        val name = it.name ?: "Unknown"
                        val address = it.address
                        val uuidList = uuids?.map { it.toString() } ?: emptyList()
                        Log.i(TAG, "UUIDs for $name ($address): $uuidList")
                        discoveredDevicesSink?.success(mapOf("name" to name, "address" to address, "uuids" to uuidList))
                    }
                }
                BluetoothAdapter.ACTION_DISCOVERY_STARTED -> Log.i(TAG, "Discovery started")
                BluetoothAdapter.ACTION_DISCOVERY_FINISHED -> Log.i(TAG, "Discovery finished")
            }
        }
    }

    private val bondReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == BluetoothDevice.ACTION_BOND_STATE_CHANGED) {
                val device = intent.getParcelableExtra<BluetoothDevice>(BluetoothDevice.EXTRA_DEVICE)
                val bondState = intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, -1)
                val address = device?.address
                if (address != null && pairingStateSink != null) {
                    val stateMap = mapOf("address" to address, "bondState" to bondState)
                    Log.i(TAG, "Bond state changed for $address: $bondState")
                    pairingStateSink?.success(stateMap)
                }
            }
        }
    }

    private fun getPairedDevices(result: MethodChannel.Result) {
        try {
            if (bluetoothAdapter == null || !bluetoothAdapter!!.isEnabled) {
                Log.e(TAG, "Bluetooth not available or not enabled")
                result.error("BLUETOOTH_NOT_AVAILABLE", "Bluetooth is not available or not enabled", null)
                return
            }

            val bondedDevices = bluetoothAdapter!!.bondedDevices
            val deviceList = bondedDevices.map { device ->
                val uuids = try {
                    device.fetchUuidsWithSdp()
                    // Note: UUIDs may not be immediately available; rely on ACTION_UUID if needed
                    device.uuids?.map { it.toString() } ?: emptyList()
                } catch (e: SecurityException) {
                    Log.w(TAG, "Permission error fetching UUIDs for ${device.address}: ${e.message}")
                    emptyList<String>()
                }
                mapOf(
                    "name" to (device.name ?: "Unknown"),
                    "address" to device.address,
                    "uuids" to uuids,
                    "type" to when (device.type) {
                        BluetoothDevice.DEVICE_TYPE_CLASSIC -> "Classic"
                        BluetoothDevice.DEVICE_TYPE_LE -> "BLE"
                        BluetoothDevice.DEVICE_TYPE_DUAL -> "Dual"
                        else -> "Unknown"
                    }
                )
            }
            Log.i(TAG, "Fetched ${deviceList.size} paired devices")
            result.success(deviceList)
        } catch (e: Exception) {
            Log.e(TAG, "Error fetching paired devices: ${e.message}")
            result.error("PAIRED_DEVICES_ERROR", e.message, null)
        }
    }

    private fun emitPairedDevices() {
        if (pairedDevicesSink == null) return
        try {
            val bondedDevices = bluetoothAdapter?.bondedDevices ?: emptySet()
            val deviceList = bondedDevices.map { device ->
                val uuids = try {
                    device.fetchUuidsWithSdp()
                    device.uuids?.map { it.toString() } ?: emptyList()
                } catch (e: SecurityException) {
                    Log.w(TAG, "Permission error fetching UUIDs for ${device.address}: ${e.message}")
                    emptyList<String>()
                }
                mapOf(
                    "name" to (device.name ?: "Unknown"),
                    "address" to device.address,
                    "uuids" to uuids,
                    "type" to when (device.type) {
                        BluetoothDevice.DEVICE_TYPE_CLASSIC -> "Classic"
                        BluetoothDevice.DEVICE_TYPE_LE -> "BLE"
                        BluetoothDevice.DEVICE_TYPE_DUAL -> "Dual"
                        else -> "Unknown"
                    }
                )
            }
            Log.i(TAG, "Emitting ${deviceList.size} paired devices to stream")
            pairedDevicesSink?.success(deviceList)
        } catch (e: Exception) {
            Log.e(TAG, "Error emitting paired devices: ${e.message}")
            pairedDevicesSink?.error("PAIRED_DEVICES_ERROR", e.message, null)
        }
    }

    private fun pairDevice(address: String, result: MethodChannel.Result) {
        val device = bluetoothAdapter?.getRemoteDevice(address)
        if (device == null) {
            Log.e(TAG, "Device not found for address: $address")
            result.error("DEVICE_NOT_FOUND", "Device not found", null)
            return
        }
        if (device.bondState == BluetoothDevice.BOND_BONDED) {
            Log.i(TAG, "Device already bonded: $address")
            result.success("Already bonded")
        } else {
            val success = device.createBond()
            if (success) {
                Log.i(TAG, "Pairing initiated for $address")
                result.success("Pairing initiated")
            } else {
                Log.e(TAG, "Failed to initiate pairing for $address")
                result.error("PAIRING_FAILED", "Failed to initiate pairing", null)
            }
        }
    }

    private fun connectToDevice(address: String, uuid: String?, result: MethodChannel.Result) {
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
                        val serviceUuid = if (uuid.isNullOrEmpty()) SPP_UUID else UUID.fromString(uuid)
                        bluetoothSocket = device.createRfcommSocketToServiceRecord(serviceUuid)
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
                startKeepAlive()
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
            stopKeepAlive()
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

    private fun sendReceipt(address: String, text: String, result: MethodChannel.Result) {
        Thread {
            try {
                if (bluetoothSocket?.isConnected != true || outputStream == null) {
                    Log.e(TAG, "Socket not connected for sending data")
                    mainHandler.post { result.error("NOT_CONNECTED", "Not connected to device", null) }
                    return@Thread
                }

                if (bluetoothSocket?.isConnected != true || outputStream == null) {
                    Log.w(TAG, "Socket not connected, attempting reconnect")
                    attemptReconnect(address, null)
                    Thread.sleep(2000) // Wait for reconnect
                    if (bluetoothSocket?.isConnected != true) {
                        mainHandler.post { result.error("NOT_CONNECTED", "Not connected to device", null) }
                        return@Thread
                    }
                }

                // ESC/POS commands
                val initialize = byteArrayOf(0x1B, 0x40) // ESC @
                val centerAlign = byteArrayOf(0x1B, 0x61, 0x01) // ESC a 1
                val printText = text.toByteArray(Charsets.US_ASCII) // Text as ASCII
                val lineFeed = byteArrayOf(0x0A) // LF
                val cutPaper = byteArrayOf(0x1D, 0x56, 0x00) // GS V 0

                // Combine commands
                val data = initialize + centerAlign + printText + lineFeed + cutPaper

                // Send data
                outputStream?.write(data)
                outputStream?.flush()
                Log.i(TAG, "Sent ESC/POS data: $text")
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

    private var keepAliveThread: Thread? = null

    private var keepAliveRunning = false

    private fun startKeepAlive() {
        keepAliveRunning = true
        keepAliveThread = Thread {
            while (keepAliveRunning && bluetoothSocket?.isConnected == true) {
                try {
                    outputStream?.write(byteArrayOf(0x1B, 0x76)) // ESC v
                    outputStream?.flush()
                    Log.d(TAG, "Sent keep-alive to TM-M30III")
                    Thread.sleep(60000) // Every 60 seconds
                } catch (e: IOException) {
                    Log.w(TAG, "Keep-alive failed: ${e.message}")
                    mainHandler.post { receivedDataSink?.error("KEEP_ALIVE_ERROR", e.message, null) }
                    break
                }
            }
            Log.d(TAG, "Keep-alive thread stopped")
        }
        keepAliveThread?.start()
    }

    private fun stopKeepAlive() {
        keepAliveRunning = false
        keepAliveThread?.interrupt()
        keepAliveThread = null
    }

    private fun attemptReconnect(address: String, uuid: String?) {
        Thread {
            try {
                if (bluetoothSocket?.isConnected == true) return@Thread
                disconnect() // Clean up existing socket
                val device = bluetoothAdapter?.getRemoteDevice(address) ?: return@Thread
                bluetoothSocket = device.createRfcommSocketToServiceRecord(
                    if (uuid.isNullOrEmpty()) SPP_UUID else UUID.fromString(uuid)
                )
                bluetoothSocket?.connect()
                inputStream = bluetoothSocket?.inputStream
                outputStream = bluetoothSocket?.outputStream
                startReading()
                startKeepAlive()
                Log.i(TAG, "Reconnected to $address")
                mainHandler.post { receivedDataSink?.success("Reconnected") }
            } catch (e: Exception) {
                Log.e(TAG, "Reconnect failed: ${e.message}")
                mainHandler.post { receivedDataSink?.error("RECONNECT_ERROR", e.message, null) }
            }
        }.start()
    }

    private fun checkPrinterStatus(result: MethodChannel.Result) {
        Thread {
            try {
                if (bluetoothSocket?.isConnected != true || outputStream == null) {
                    mainHandler.post { result.error("NOT_CONNECTED", "Not connected", null) }
                    return@Thread
                }
                outputStream?.write(byteArrayOf(0x1B, 0x76)) // ESC v
                outputStream?.flush()
                val buffer = ByteArray(1)
                val bytes = inputStream?.read(buffer) ?: 0
                if (bytes > 0) {
                    val status = buffer[0].toInt()
                    Log.i(TAG, "Printer status: $status")
                    val statusMap = mapOf(
                        "online" to (status and 0x04 == 0), // Bit 2: 0 = online
                        "paperOut" to (status and 0x0C != 0) // Bit 3: 1 = paper out
                    )
                    mainHandler.post { result.success(statusMap) }
                } else {
                    mainHandler.post { result.success(mapOf("online" to false)) }
                }
            } catch (e: IOException) {
                Log.e(TAG, "Status check failed: ${e.message}")
                mainHandler.post { result.error("STATUS_ERROR", e.message, null) }
            }
        }.start()
    }

    override fun onDestroy() {
        super.onDestroy()
        stopScanning()
        disconnect()
        try {
            unregisterReceiver(receiver)
        } catch (e: IllegalArgumentException) {
            Log.w(TAG, "Receiver not registered")
        }
        try {
            unregisterReceiver(bondReceiver)
        } catch (e: IllegalArgumentException) {
            Log.w(TAG, "Bond receiver not registered")
        }
    }
}