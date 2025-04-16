package com.example.demo_project_atcom

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

class BluetoothLeManager(
    private val context: Context,
    private val bluetoothAdapter: BluetoothAdapter?,
    private val eventCallback: (BluetoothEvent) -> Unit
) {
    private val TAG = "BluetoothLeManager"
    private var bluetoothLeScanner = bluetoothAdapter?.bluetoothLeScanner
    private var bluetoothGatt: BluetoothGatt? = null
    private val isBleScanning = AtomicBoolean(false)
    private val mainHandler = Handler(Looper.getMainLooper())

    private val bleScanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult?) {
            result?.device?.let { device ->
                val name = device.name ?: "Unknown"
                val address = device.address
                Log.i(TAG, "Found BLE device: $name ($address)")
                eventCallback(BluetoothEvent.DiscoveredDevice(name, address, emptyList(), device.type.toString(), true))
            }
        }

        override fun onScanFailed(errorCode: Int) {
            Log.e(TAG, "BLE scan failed with error code: $errorCode")
            eventCallback(BluetoothEvent.Error("BLE_SCAN_FAILED", "BLE scan failed with code: $errorCode"))
        }
    }

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt?, status: Int, newState: Int) {
            when (newState) {
                android.bluetooth.BluetoothProfile.STATE_CONNECTED -> {
                    Log.i(TAG, "BLE connected")
                    mainHandler.post {
                        eventCallback(BluetoothEvent.ReceivedData("BLE Connected"))
                        gatt?.discoverServices()
                    }
                }
                android.bluetooth.BluetoothProfile.STATE_DISCONNECTED -> {
                    Log.i(TAG, "BLE disconnected")
                    mainHandler.post { eventCallback(BluetoothEvent.ReceivedData("BLE Disconnected")) }
                    gatt?.close()
                }
                else -> Log.i(TAG, "BLE connection state: $newState")
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt?, status: Int) {
            if (status == BluetoothGatt.GATT_SUCCESS) {
                Log.i(TAG, "BLE services discovered")
                gatt?.services?.forEach { service ->
                    service.characteristics.forEach { characteristic ->
                        if (characteristic.properties and BluetoothGattCharacteristic.PROPERTY_NOTIFY != 0) {
                            gatt.setCharacteristicNotification(characteristic, true)
                            val descriptor = characteristic.getDescriptor(
                                UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
                            )
                            descriptor?.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                            gatt.writeDescriptor(descriptor)
                        }
                    }
                }
            } else {
                Log.w(TAG, "BLE service discovery failed with status: $status")
                mainHandler.post { eventCallback(BluetoothEvent.Error("BLE_SERVICE_ERROR", "Service discovery failed")) }
            }
        }

        override fun onCharacteristicRead(
            gatt: BluetoothGatt?,
            characteristic: BluetoothGattCharacteristic?,
            status: Int
        ) {
            if (status == BluetoothGatt.GATT_SUCCESS) {
                characteristic?.value?.let { value ->
                    val data = String(value)
                    Log.i(TAG, "BLE characteristic read: $data")
                    mainHandler.post { eventCallback(BluetoothEvent.ReceivedData(data)) }
                }
            } else {
                Log.w(TAG, "BLE characteristic read failed with status: $status")
                mainHandler.post { eventCallback(BluetoothEvent.Error("BLE_READ_ERROR", "Characteristic read failed")) }
            }
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt?,
            characteristic: BluetoothGattCharacteristic?
        ) {
            characteristic?.value?.let { value ->
                val data = String(value)
                Log.i(TAG, "BLE characteristic changed: $data")
                mainHandler.post { eventCallback(BluetoothEvent.ReceivedData(data)) }
            }
        }

        override fun onCharacteristicWrite(
            gatt: BluetoothGatt?,
            characteristic: BluetoothGattCharacteristic?,
            status: Int
        ) {
            if (status == BluetoothGatt.GATT_SUCCESS) {
                Log.i(TAG, "BLE characteristic write successful")
            } else {
                Log.w(TAG, "BLE characteristic write failed with status: $status")
                mainHandler.post { eventCallback(BluetoothEvent.Error("BLE_WRITE_ERROR", "Characteristic write failed")) }
            }
        }
    }

    fun startScanning(timeoutSeconds: Int?, result: MethodChannel.Result) {
        Log.i(TAG, "Starting BLE scanning")
        if (bluetoothAdapter == null || !bluetoothAdapter.isEnabled) {
            Log.e(TAG, "Bluetooth not available or not enabled")
            result.error("BLUETOOTH_NOT_AVAILABLE", "Bluetooth is not available or not enabled", null)
            return
        }

        // Reinitialize scanner in case Bluetooth state changed
        bluetoothLeScanner = bluetoothAdapter.bluetoothLeScanner
        if (bluetoothLeScanner == null) {
            Log.e(TAG, "BLE scanner not available")
            result.error("BLE_SCANNER_NOT_AVAILABLE", "BLE scanner not available", null)
            return
        }

        if (isBleScanning.get()) {
            stopScanningInternal()
            Log.i(TAG, "Stopped existing BLE scan before starting new one")
        }

        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()

        try {
            bluetoothLeScanner?.startScan(null, settings, bleScanCallback)
            isBleScanning.set(true)
            Log.i(TAG, "BLE scan started successfully")
            result.success(null)
        } catch (e: SecurityException) {
            Log.e(TAG, "BLE scan failed due to permissions: ${e.message}")
            eventCallback(BluetoothEvent.Error("BLE_SCAN_ERROR", "Permission denied for BLE scan"))
            result.error("BLE_SCAN_ERROR", "Permission denied for BLE scan", null)
            return
        }

        if (timeoutSeconds != null && timeoutSeconds > 0) {
            mainHandler.postDelayed({
                if (isBleScanning.get()) {
                    stopScanningInternal()
                    Log.i(TAG, "BLE scan stopped due to timeout")
                    eventCallback(BluetoothEvent.DiscoveredDevice("", "", emptyList(), "", true, event = "timeout", message = "BLE scan stopped after $timeoutSeconds seconds"))
                }
            }, timeoutSeconds * 1000L)
        }
    }

    private fun stopScanningInternal() {
        if (isBleScanning.get() && bluetoothLeScanner != null) {
            try {
                bluetoothLeScanner?.stopScan(bleScanCallback)
                isBleScanning.set(false)
                Log.i(TAG, "BLE scan stopped")
            } catch (e: SecurityException) {
                Log.w(TAG, "Failed to stop BLE scan: ${e.message}")
            }
        }
    }

    fun stopScanning(result: MethodChannel.Result) {
        Log.i(TAG, "Stopping BLE scanning")
        stopScanningInternal()
        result.success(null)
    }

    fun getPairedDevices(): List<Map<String, Any>> {
        if (bluetoothAdapter == null || !bluetoothAdapter.isEnabled) {
            Log.e(TAG, "Bluetooth not available or not enabled")
            return emptyList()
        }

        return try {
            val bondedDevices = bluetoothAdapter.bondedDevices.filter {
                it.type == BluetoothDevice.DEVICE_TYPE_LE || it.type == BluetoothDevice.DEVICE_TYPE_DUAL
            }
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
                    "type" to "BLE",
                    "isBle" to true
                )
            }.also { Log.i(TAG, "Fetched ${it.size} paired BLE devices") }
        } catch (e: Exception) {
            Log.e(TAG, "Error fetching paired devices: ${e.message}")
            emptyList()
        }
    }

    fun connectToDevice(address: String, result: MethodChannel.Result) {
        Thread {
            try {
                val device = bluetoothAdapter?.getRemoteDevice(address)
                if (device == null) {
                    Log.e(TAG, "BLE device not found for address: $address")
                    mainHandler.post { result.error("DEVICE_NOT_FOUND", "Device not found", null) }
                    return@Thread
                }

                stopScanningInternal()
                Log.i(TAG, "BLE scan stopped before connecting to $address")

                bluetoothGatt?.close()
                bluetoothGatt = device.connectGatt(context, false, gattCallback)
                Log.i(TAG, "Initiated BLE connection to $address")
                mainHandler.post { result.success(null) }
            } catch (e: Exception) {
                Log.e(TAG, "Unexpected error during BLE connection: ${e.message}")
                mainHandler.post { result.error("BLE_CONNECT_ERROR", e.message, null) }
            }
        }.start()
    }

    fun disconnect(result: MethodChannel.Result) {
        Log.i(TAG, "Disconnecting BLE")
        try {
            bluetoothGatt?.disconnect()
            bluetoothGatt?.close()
            bluetoothGatt = null
            Log.i(TAG, "BLE disconnected successfully")
            result.success(null)
        } catch (e: Exception) {
            Log.w(TAG, "Error during BLE disconnect: ${e.message}")
            result.success(null)
        }
    }

    fun sendData(data: String, result: MethodChannel.Result) {
        Thread {
            try {
                val gatt = bluetoothGatt
                if (gatt == null) {
                    Log.e(TAG, "BLE not connected")
                    mainHandler.post { result.error("NOT_CONNECTED", "Not connected to BLE device", null) }
                    return@Thread
                }

                val serviceUuid = UUID.fromString("0000180d-0000-1000-8000-00805f9b34fb")
                val characteristicUuid = UUID.fromString("00002a37-0000-1000-8000-00805f9b34fb")
                val characteristic = gatt.getService(serviceUuid)?.getCharacteristic(characteristicUuid)

                if (characteristic == null) {
                    Log.e(TAG, "Characteristic not found")
                    mainHandler.post { result.error("CHARACTERISTIC_NOT_FOUND", "Required characteristic not found", null) }
                    return@Thread
                }

                characteristic.value = data.toByteArray()
                characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
//                characteristic.writeProperties = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                val success = gatt.writeCharacteristic(characteristic)
                if (success) {
                    Log.i(TAG, "Sent BLE data: $data")
                    mainHandler.post { result.success(null) }
                } else {
                    Log.e(TAG, "Failed to send BLE data")
                    mainHandler.post { result.error("BLE_WRITE_ERROR", "Failed to write BLE data", null) }
                }
            } catch (e: Exception) {
                Log.e(TAG, "BLE send data failed: ${e.message}")
                mainHandler.post { result.error("BLE_SEND_ERROR", e.message, null) }
            }
        }.start()
    }

    fun checkStatus(result: MethodChannel.Result) {
        Thread {
            try {
                val gatt = bluetoothGatt
                if (gatt == null) {
                    mainHandler.post { result.error("NOT_CONNECTED", "Not connected to BLE device", null) }
                    return@Thread
                }

                val serviceUuid = UUID.fromString("0000180d-0000-1000-8000-00805f9b34fb")
                val characteristicUuid = UUID.fromString("00002a37-0000-1000-8000-00805f9b34fb")
                val characteristic = gatt.getService(serviceUuid)?.getCharacteristic(characteristicUuid)

                if (characteristic == null) {
                    Log.e(TAG, "Status characteristic not found")
                    mainHandler.post { result.error("CHARACTERISTIC_NOT_FOUND", "Status characteristic not found", null) }
                    return@Thread
                }

                val success = gatt.readCharacteristic(characteristic)
                if (success) {
                    Log.i(TAG, "Initiated BLE status check")
                    mainHandler.post { result.success(mapOf("online" to true, "paperOut" to false)) }
                } else {
                    Log.e(TAG, "Failed to initiate BLE status check")
                    mainHandler.post { result.error("BLE_STATUS_ERROR", "Failed to read status", null) }
                }
            } catch (e: Exception) {
                Log.e(TAG, "BLE status check failed: ${e.message}")
                mainHandler.post { result.error("BLE_STATUS_ERROR", e.message, null) }
            }
        }.start()
    }

    fun cleanup() {
        Log.i(TAG, "Cleaning up BluetoothLeManager")
        stopScanningInternal()
        try {
            bluetoothGatt?.disconnect()
            bluetoothGatt?.close()
            bluetoothGatt = null
            Log.i(TAG, "BLE disconnected during cleanup")
        } catch (e: Exception) {
            Log.w(TAG, "Error during BLE disconnect in cleanup: ${e.message}")
        }
    }
}