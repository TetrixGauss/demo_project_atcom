package com.example.demo_project_atcom

import android.bluetooth.BluetoothAdapter
import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import android.os.Handler
import android.os.Looper
import android.util.Log

class BluetoothPlugin : FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler {
    private lateinit var context: Context
    private lateinit var methodChannel: MethodChannel
    private lateinit var discoveredDevicesChannel: EventChannel
    private lateinit var receivedDataChannel: EventChannel
    private lateinit var pairingStateChannel: EventChannel
    private lateinit var pairedDevicesChannel: EventChannel
    private var discoveredSink: EventChannel.EventSink? = null
    private var receivedDataSink: EventChannel.EventSink? = null
    private var pairingStateSink: EventChannel.EventSink? = null
    private var pairedDevicesSink: EventChannel.EventSink? = null
    private var bluetoothClassicManager: BluetoothClassicManager? = null
    private var bluetoothLeManager: BluetoothLeManager? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val TAG = "BluetoothPlugin"

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, "com.example/bluetooth")
        discoveredDevicesChannel = EventChannel(binding.binaryMessenger, "com.example/bluetooth_discovered_devices")
        receivedDataChannel = EventChannel(binding.binaryMessenger, "com.example/bluetooth_received_data")
        pairingStateChannel = EventChannel(binding.binaryMessenger, "com.example/bluetooth_pairing_state")
        pairedDevicesChannel = EventChannel(binding.binaryMessenger, "com.example/bluetooth_paired_devices")
        methodChannel.setMethodCallHandler(this)
        discoveredDevicesChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                discoveredSink = events
            }
            override fun onCancel(arguments: Any?) {
                discoveredSink = null
            }
        })
        receivedDataChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                receivedDataSink = events
            }
            override fun onCancel(arguments: Any?) {
                receivedDataSink = null
            }
        })
        pairingStateChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                pairingStateSink = events
            }
            override fun onCancel(arguments: Any?) {
                pairingStateSink = null
            }
        })
        pairedDevicesChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                pairedDevicesSink = events
                // Send initial paired devices when stream is listened to
                sendPairedDevices()
            }
            override fun onCancel(arguments: Any?) {
                pairedDevicesSink = null
            }
        })

        val bluetoothAdapter = BluetoothAdapter.getDefaultAdapter()
        bluetoothClassicManager = BluetoothClassicManager(context, bluetoothAdapter, ::handleBluetoothEvent)
        bluetoothLeManager = BluetoothLeManager(context, bluetoothAdapter, ::handleBluetoothEvent)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        discoveredDevicesChannel.setStreamHandler(null)
        receivedDataChannel.setStreamHandler(null)
        pairingStateChannel.setStreamHandler(null)
        pairedDevicesChannel.setStreamHandler(null)
        bluetoothClassicManager?.cleanup()
        bluetoothLeManager?.cleanup()
        discoveredSink = null
        receivedDataSink = null
        pairingStateSink = null
        pairedDevicesSink = null
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "startScanning" -> {
                val isBLE = call.argument<Boolean>("isBLE") ?: false
                val timeout = call.argument<Int>("timeout")
                if (isBLE) {
                    bluetoothLeManager?.startScanning(timeout, result)
                } else {
                    bluetoothClassicManager?.startScanning(timeout, result)
                }
            }
            "stopScanning" -> {
                bluetoothClassicManager?.stopScanning(result)
                bluetoothLeManager?.stopScanning(object : Result {
                    override fun success(res: Any?) {
                        result.success(null)
                    }
                    override fun error(code: String, message: String?, details: Any?) {
                        result.error(code, message, details)
                    }
                    override fun notImplemented() {
                        result.notImplemented()
                    }
                })
            }
            "pairDevice" -> {
                val address = call.argument<String>("address")
                if (address != null) {
                    bluetoothClassicManager?.pairDevice(address, result)
                } else {
                    result.error("INVALID_ARGUMENT", "Device address is required", null)
                }
            }
            "connectToDevice" -> {
                val isBLE = call.argument<Boolean>("isBLE") ?: false
                val address = call.argument<String>("address")
                val uuid = call.argument<String>("uuid")
                if (address != null) {
                    if (isBLE) {
                        bluetoothLeManager?.connectToDevice(address, result)
                    } else {
                        bluetoothClassicManager?.connectToDevice(address, uuid, result)
                    }
                } else {
                    result.error("INVALID_ARGUMENT", "Device address is required", null)
                }
            }
            "disconnect" -> {
                bluetoothClassicManager?.disconnect(object : Result {
                    override fun success(res: Any?) {
                        bluetoothLeManager?.disconnect(result)
                    }
                    override fun error(code: String, message: String?, details: Any?) {
                        result.error(code, message, details)
                    }
                    override fun notImplemented() {
                        result.notImplemented()
                    }
                })
            }
            "sendData" -> {
                val address = call.argument<String>("address")
                val data = call.argument<String>("data")
                if (address != null && data != null) {
                    bluetoothClassicManager?.sendReceipt(address, data, result)
                    bluetoothLeManager?.sendData(data, object : Result {
                        override fun success(res: Any?) {
                            result.success(null)
                        }
                        override fun error(code: String, message: String?, details: Any?) {
                            result.error(code, message, details)
                        }
                        override fun notImplemented() {
                            result.notImplemented()
                        }
                    })
                } else {
                    result.error("INVALID_ARGUMENT", "Address and data are required", null)
                }
            }
            "checkStatus" -> {
                bluetoothClassicManager?.checkStatus(object : Result {
                    override fun success(res: Any?) {
                        result.success(res)
                    }
                    override fun error(code: String, message: String?, details: Any?) {
                        bluetoothLeManager?.checkStatus(result)
                    }
                    override fun notImplemented() {
                        result.notImplemented()
                    }
                })
            }
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        // Not used directly since we have multiple channels
    }

    override fun onCancel(arguments: Any?) {
        // Not used directly
    }

    private fun handleBluetoothEvent(event: BluetoothEvent) {
        mainHandler.post {
            when (event) {
                is BluetoothEvent.DiscoveredDevice -> {
                    val deviceMap = event.toMap()
                    Log.i(TAG, "Streaming discovered device: $deviceMap")
                    discoveredSink?.success(deviceMap)
                }
                is BluetoothEvent.ReceivedData -> {
                    Log.i(TAG, "Streaming received data: ${event.data}")
                    receivedDataSink?.success(event.data)
                }
                is BluetoothEvent.Error -> {
                    Log.e(TAG, "Streaming error: ${event.code} - ${event.message}")
                    discoveredSink?.success(mapOf("event" to "error", "code" to event.code, "message" to event.message))
                }
                is BluetoothEvent.PairingState -> {
                    val stateMap = event.toMap()
                    Log.i(TAG, "Streaming pairing state: $stateMap")
                    pairingStateSink?.success(stateMap)
                }
            }
        }
    }

    private fun sendPairedDevices() {
        mainHandler.post {
            val classicDevices = bluetoothClassicManager?.getPairedDevices() ?: emptyList()
            val bleDevices = bluetoothLeManager?.getPairedDevices() ?: emptyList()
            val allDevices = (classicDevices + bleDevices).distinctBy { it["address"] }
            allDevices.forEach { device ->
                Log.i(TAG, "Streaming paired device: $device")
                pairedDevicesSink?.success(device)
            }
        }
    }
}