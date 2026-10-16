import Foundation

struct DevelopParams: Codable, Equatable {
    var exposure = 0.0
    var temperature = 0.0
    var tint = 0.0
    var highlights = 0.0
    var shadows = 0.0
    var contrast = 0.0
    var saturation = 0.0
    var flat = false
}

struct ColorParams: Codable, Equatable {
    var look = "none"
    var intensity = 1.0
}
