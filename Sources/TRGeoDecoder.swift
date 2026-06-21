import Foundation
import CoreLocation

/// 地理位置解码器 - 将经纬度转换为地址
class TRGeoDecoder: ObservableObject {
    static let shared = TRGeoDecoder()
    
    private let geocoder = CLGeocoder()
    private var cache: [String: String] = [:]
    
    func decodeLocation(latitude: Double, longitude: Double) async -> String? {
        let key = "\(latitude),\(longitude)"
        if let cached = cache[key] { return cached }
        
        let location = CLLocation(latitude: latitude, longitude: longitude)
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            if let placemark = placemarks.first {
                let address = [
                    placemark.locality,
                    placemark.administrativeArea,
                    placemark.country
                ].compactMap { $0 }.joined(separator: ", ")
                cache[key] = address
                return address
            }
        } catch {
            print("Geocoding failed: \(error)")
        }
        return nil
    }
}