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
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
//import java.nio.charset.Charsets
import java.util.UUID

class BluetoothClassicManager(
    private val context: Context,
    private val bluetoothAdapter: BluetoothAdapter?,
    private val eventCallback: (BluetoothEvent) -> Unit
) {
    private val TAG = "BluetoothClassicManager"
    private val SPP_UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
    private var bluetoothSocket: BluetoothSocket? = null
    private var inputStream: InputStream? = null
    private var outputStream: OutputStream? = null
    private var readingThread: Thread? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var discoveryTimeoutRunnable: Runnable? = null
    private var keepAliveThread: Thread? = null
    private var keepAliveRunning = false

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
                        eventCallback(BluetoothEvent.DiscoveredDevice(name, address, uuids, type.toString(), false))
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
                        eventCallback(BluetoothEvent.DiscoveredDevice(name, address, uuidList, "Unknown", false))
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
                if (address != null) {
                    Log.i(TAG, "Bond state changed for $address: $bondState")
                    eventCallback(BluetoothEvent.PairingState(address, bondState))
                }
            }
        }
    }

    init {
        val bondFilter = IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED)
        context.registerReceiver(bondReceiver, bondFilter)
    }

    fun startScanning(timeoutSeconds: Int?, result: MethodChannel.Result) {
        Log.i(TAG, "Starting Bluetooth discovery")
        if (bluetoothAdapter == null || !bluetoothAdapter.isEnabled) {
            Log.e(TAG, "Bluetooth not available or not enabled")
            result.error("BLUETOOTH_NOT_AVAILABLE", "Bluetooth is not available or not enabled", null)
            return
        }

        if (bluetoothAdapter.isDiscovering) {
            bluetoothAdapter.cancelDiscovery()
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
            context.registerReceiver(receiver, filter)
            Log.i(TAG, "Receiver registered for discovery")
        } catch (e: IllegalArgumentException) {
            Log.w(TAG, "Receiver already registered or error: ${e.message}")
        }

        if (bluetoothAdapter.startDiscovery()) {
            Log.i(TAG, "Discovery started successfully")
            result.success(null)
        } else {
            Log.e(TAG, "Failed to start discovery")
            eventCallback(BluetoothEvent.Error("DISCOVERY_ERROR", "Failed to start discovery"))
            result.error("DISCOVERY_ERROR", "Failed to start discovery", null)
        }

        if (timeoutSeconds != null && timeoutSeconds > 0) {
            discoveryTimeoutRunnable = Runnable {
                if (bluetoothAdapter.isDiscovering) {
                    bluetoothAdapter.cancelDiscovery()
                    Log.i(TAG, "Discovery stopped due to timeout")
                    eventCallback(BluetoothEvent.DiscoveredDevice("", "", emptyList(), "", false, event = "timeout", message = "Discovery stopped after $timeoutSeconds seconds"))
                }
            }
            mainHandler.postDelayed(discoveryTimeoutRunnable!!, timeoutSeconds * 1000L)
        }
    }

    fun stopScanning(result: MethodChannel.Result) {
        Log.i(TAG, "Stopping Bluetooth discovery")
        discoveryTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
        discoveryTimeoutRunnable = null

        if (bluetoothAdapter?.isDiscovering == true) {
            bluetoothAdapter.cancelDiscovery()
            Log.i(TAG, "Discovery canceled")
        }

        try {
            context.unregisterReceiver(receiver)
            Log.i(TAG, "Receiver unregistered")
        } catch (e: IllegalArgumentException) {
            Log.w(TAG, "Receiver not registered: ${e.message}")
        }
        result.success(null)
    }

    fun getPairedDevices(): List<Map<String, Any>> {
        if (bluetoothAdapter == null || !bluetoothAdapter.isEnabled) {
            Log.e(TAG, "Bluetooth not available or not enabled")
            return emptyList()
        }

        return try {
            val bondedDevices = bluetoothAdapter.bondedDevices
            bondedDevices.map { device ->
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
                    },
                    "isBle" to false
                )
            }.also { Log.i(TAG, "Fetched ${it.size} paired classic devices") }
        } catch (e: Exception) {
            Log.e(TAG, "Error fetching paired devices: ${e.message}")
            emptyList()
        }
    }

    fun pairDevice(address: String, result: MethodChannel.Result) {
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

    fun connectToDevice(address: String, uuid: String?, result: MethodChannel.Result) {
        Thread {
            try {
                val device = bluetoothAdapter?.getRemoteDevice(address)
                if (device == null) {
                    Log.e(TAG, "Device not found for address: $address")
                    mainHandler.post { result.error("DEVICE_NOT_FOUND", "Device not found", null) }
                    return@Thread
                }

                if (device.bondState != BluetoothDevice.BOND_BONDED) {
                    Log.w(TAG, "Device not bonded: $address")
                    mainHandler.post { result.error("NOT_BONDED", "Please pair the device first", null) }
                    return@Thread
                }

                bluetoothAdapter?.cancelDiscovery()
                Log.i(TAG, "Discovery canceled before connecting to $address")

                bluetoothSocket?.let {
                    try {
                        it.close()
                    } catch (e: IOException) {
                        Log.w(TAG, "Failed to close old socket: ${e.message}")
                    }
                }

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
                            Thread.sleep(1000)
                            retryCount++
                        } else {
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

    fun disconnect(result: MethodChannel.Result) {
        Log.i(TAG, "Disconnecting Bluetooth")
        try {
            stopKeepAlive()
            readingThread?.interrupt()
            readingThread = null
            inputStream?.close()
            outputStream?.close()
            bluetoothSocket?.close()
            bluetoothSocket = null
            inputStream = null
            outputStream = null
            Log.i(TAG, "Disconnected successfully")
            result.success(null)
        } catch (e: IOException) {
            Log.w(TAG, "Error during disconnect: ${e.message}")
            result.success(null)
        }
    }

    fun sendReceipt(address: String, text: String, result: MethodChannel.Result) {
        Thread {
            try {
                if (bluetoothSocket?.isConnected != true || outputStream == null) {
                    Log.e(TAG, "Socket not connected for sending data")
                    mainHandler.post { result.error("NOT_CONNECTED", "Not connected to device", null) }
                    return@Thread
                }

                val initialize = byteArrayOf(0x1B, 0x40)
                val centerAlign = byteArrayOf(0x1B, 0x61, 0x01)
                val printText = text.toByteArray(Charsets.US_ASCII)
                val lineFeed = byteArrayOf(0x0A)
                val cutPaper = byteArrayOf(0x1D, 0x56, 0x00)

                val data = initialize + centerAlign + printText + lineFeed + cutPaper

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

    fun checkStatus(result: MethodChannel.Result) {
        Thread {
            try {
                if (bluetoothSocket?.isConnected != true || outputStream == null) {
                    mainHandler.post { result.error("NOT_CONNECTED", "Not connected", null) }
                    return@Thread
                }
                outputStream?.write(byteArrayOf(0x1B, 0x76))
                outputStream?.flush()
                val buffer = ByteArray(1)
                val bytes = inputStream?.read(buffer) ?: 0
                if (bytes > 0) {
                    val status = buffer[0].toInt()
                    Log.i(TAG, "Printer status: $status")
                    val statusMap = mapOf(
                        "online" to (status and 0x04 == 0),
                        "paperOut" to (status and 0x0C != 0)
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

    private fun startReading() {
        readingThread = Thread {
            val buffer = ByteArray(1024)
            var bytes: Int
            Log.i(TAG, "Starting read thread")
            while (!Thread.currentThread().isInterrupted && bluetoothSocket?.isConnected == true) {
                try {
                    bytes = inputStream?.read(buffer) ?: 0
                    if (bytes > 0) {
                        val data = String(buffer, 0, bytes)
                        Log.i(TAG, "Received data: $data")
                        eventCallback(BluetoothEvent.ReceivedData(data))
                    }
                } catch (e: IOException) {
                    Log.w(TAG, "Read failed: ${e.message}")
                    if (!Thread.currentThread().isInterrupted) {
                        eventCallback(BluetoothEvent.Error("READ_ERROR", e.message))
                    }
                    break
                }
            }
            Log.i(TAG, "Read thread stopped")
        }
        readingThread?.start()
    }

    private fun startKeepAlive() {
        keepAliveRunning = true
        keepAliveThread = Thread {
            while (keepAliveRunning && bluetoothSocket?.isConnected == true) {
                try {
                    outputStream?.write(byteArrayOf(0x1B, 0x76))
                    outputStream?.flush()
                    Log.d(TAG, "Sent keep-alive to TM-M30III")
                    Thread.sleep(60000)
                } catch (e: IOException) {
                    Log.w(TAG, "Keep-alive failed: ${e.message}")
                    eventCallback(BluetoothEvent.Error("KEEP_ALIVE_ERROR", e.message))
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

                // Perform disconnection without MethodChannel.Result
                try {
                    stopKeepAlive()
                    readingThread?.interrupt()
                    readingThread = null
                    inputStream?.close()
                    outputStream?.close()
                    bluetoothSocket?.close()
                    bluetoothSocket = null
                    inputStream = null
                    outputStream = null
                    Log.i(TAG, "Disconnected during reconnect attempt")
                } catch (e: IOException) {
                    Log.w(TAG, "Error during disconnect for reconnect: ${e.message}")
                }

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
                eventCallback(BluetoothEvent.ReceivedData("Reconnected"))
            } catch (e: Exception) {
                Log.e(TAG, "Reconnect failed: ${e.message}")
                eventCallback(BluetoothEvent.Error("RECONNECT_ERROR", e.message))
            }
        }.start()
    }

    fun cleanup() {
        Log.i(TAG, "Cleaning up BluetoothClassicManager")

        // Stop scanning
        discoveryTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
        discoveryTimeoutRunnable = null
        if (bluetoothAdapter?.isDiscovering == true) {
            bluetoothAdapter.cancelDiscovery()
            Log.i(TAG, "Discovery canceled during cleanup")
        }
        try {
            context.unregisterReceiver(receiver)
            Log.i(TAG, "Receiver unregistered during cleanup")
        } catch (e: IllegalArgumentException) {
            Log.w(TAG, "Receiver not registered: ${e.message}")
        }

        // Disconnect
        try {
            stopKeepAlive()
            readingThread?.interrupt()
            readingThread = null
            inputStream?.close()
            outputStream?.close()
            bluetoothSocket?.close()
            bluetoothSocket = null
            inputStream = null
            outputStream = null
            Log.i(TAG, "Disconnected during cleanup")
        } catch (e: IOException) {
            Log.w(TAG, "Error during disconnect in cleanup: ${e.message}")
        }

        // Unregister bond receiver
        try {
            context.unregisterReceiver(bondReceiver)
            Log.i(TAG, "Bond receiver unregistered during cleanup")
        } catch (e: IllegalArgumentException) {
            Log.w(TAG, "Bond receiver not registered: ${e.message}")
        }
    }
}