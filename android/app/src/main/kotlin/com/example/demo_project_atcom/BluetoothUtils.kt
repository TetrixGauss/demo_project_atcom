package com.example.demo_project_atcom

sealed class BluetoothEvent {
    data class DiscoveredDevice(
        val name: String,
        val address: String,
        val uuids: List<String>,
        val type: String,
        val isBle: Boolean,
        val event: String? = null,
        val message: String? = null
    ) : BluetoothEvent() {
        fun toMap(): Map<String, Any?> {
            return if (event != null && message != null) {
                mapOf("event" to event, "message" to message)
            } else {
                mapOf(
                    "name" to name,
                    "address" to address,
                    "uuids" to uuids,
                    "type" to type,
                    "isBle" to isBle
                )
            }
        }
    }

    data class ReceivedData(val data: String) : BluetoothEvent()
    data class Error(val code: String, val message: String?) : BluetoothEvent()
    data class PairingState(val address: String, val bondState: Int) : BluetoothEvent() {
        fun toMap(): Map<String, Any> = mapOf("address" to address, "bondState" to bondState)
    }
}