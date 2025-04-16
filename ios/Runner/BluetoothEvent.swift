import Foundation

// MARK: - Bluetooth Event Types
enum BluetoothEvent {
    struct DiscoveredDevice {
        let name: String
        let address: String
        let uuids: [String]
        let type: String
        let isBle: Bool
        let event: String?
        let message: String?
        
        func toDictionary() -> [String: Any] {
            if let event = event, let message = message {
                return ["event": event, "message": message]
            }
            return [
                "name": name,
                "address": address,
                "uuids": uuids,
                "type": type,
                "isBle": isBle
            ]
        }
    }
    
    struct ReceivedData {
        let data: String
    }
    
    struct Error {
        let code: String
        let message: String?
    }
}
