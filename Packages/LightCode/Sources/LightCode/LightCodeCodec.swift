import Foundation

/// Linear RGB samples, in the range 0...1. Camera samples stay on-device.
public struct LightColor: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public init(_ red: Double, _ green: Double, _ blue: Double) { self.red = red; self.green = green; self.blue = blue }
    fileprivate func distance(_ other: Self) -> Double { pow(red-other.red,2)+pow(green-other.green,2)+pow(blue-other.blue,2) }
}
public enum LightCodeError: Error { case invalidCode }

/// Version 1: four orientation corners, two reference colors, 24 code bits,
/// an eight-bit version marker and CRC-16. Each of the 48 bits has an inverse
/// partner. A frame always carries the complete payload; animation is decoration.
public enum LightCodeCodec {
    public static let side = 12
    public static let zero = LightColor(0.08, 0.88, 0.98)
    public static let one = LightColor(0.98, 0.15, 0.78)
    private static let corners = [LightColor(1,1,1), LightColor(1,0.12,0.08), LightColor(1,0.9,0.06), LightColor(0.1,0.25,1)]
    private static let positions = (1...10).flatMap { row in (1...10).map { row*side+$0 } }
    public static func isValidCode(_ code: String) -> Bool { code.utf8.count == 6 && code.utf8.allSatisfy { (48...57).contains($0) } }
    public static func encode(_ code: String) throws -> [LightColor] {
        guard isValidCode(code), let value=UInt32(code) else { throw LightCodeError.invalidCode }
        let bytes: [UInt8] = [0xA1,UInt8((value>>16)&255),UInt8((value>>8)&255),UInt8(value&255)]
        let checksum=crc(bytes)
        let payload=bytes+[UInt8(checksum>>8),UInt8(checksum&255)]
        let bits=payload.flatMap { byte in (0..<8).map { (byte>>(7-$0))&1 } }
        var cells=Array(repeating: LightColor(0.04,0.04,0.06),count:side*side)
        cells[0]=corners[0]; cells[11]=corners[1]; cells[143]=corners[2]; cells[132]=corners[3]
        cells[5]=zero; cells[6]=one; cells[137]=zero; cells[138]=one
        for index in 0..<48 { cells[positions[index*2]]=bits[index]==0 ? zero:one; cells[positions[index*2+1]]=bits[index]==0 ? one:zero }
        for index in 96..<100 { cells[positions[index]]=index%2==0 ? zero:one }
        return cells
    }
    public static func decode(_ cells: [LightColor]) -> String? {
        guard cells.count==side*side else { return nil }
        var oriented=cells
        for _ in 0..<4 {
            if let result=decodeOriented(oriented) { return result }
            let old=oriented; oriented=(0..<144).map { old[(11-($0%12))*12+($0/12)] }
        }
        return nil
    }
    private static func decodeOriented(_ cells:[LightColor]) -> String? {
        let cornerIndices=[0,11,143,132]
        for index in 0..<4 {
            let distances=corners.map { cells[cornerIndices[index]].distance($0) }
            guard distances[index]==distances.min(), distances[index]<0.45 else { return nil }
        }
        let low=cells[5], high=cells[6]
        guard low.distance(high)>0.25, low.distance(cells[137])<0.12, high.distance(cells[138])<0.12 else { return nil }
        func bit(_ sample:LightColor) -> UInt8? {
            let d0=sample.distance(low),d1=sample.distance(high)
            guard min(d0,d1)<0.15, abs(d0-d1)>0.12 else { return nil }
            return d0<d1 ? 0:1
        }
        var bits=[UInt8]()
        for index in 0..<48 {
            guard let a=bit(cells[positions[index*2]]),let b=bit(cells[positions[index*2+1]]),a != b else { return nil }; bits.append(a)
        }
        for index in 96..<100 { guard bit(cells[positions[index]])==UInt8(index%2) else { return nil } }
        var bytes=[UInt8]()
        for index in 0..<6 { bytes.append(bits[(index*8)..<(index*8+8)].reduce(0) { ($0<<1)|$1 }) }
        guard bytes[0]==0xA1, crc(Array(bytes.prefix(4)))==(UInt16(bytes[4])<<8|UInt16(bytes[5])) else { return nil }
        let value=UInt32(bytes[1])<<16|UInt32(bytes[2])<<8|UInt32(bytes[3])
        guard value<1_000_000 else { return nil }; return String(format:"%06u",value)
    }
    private static func crc(_ bytes:[UInt8]) -> UInt16 {
        var result:UInt16=0xFFFF
        for byte in bytes { result ^= UInt16(byte)<<8; for _ in 0..<8 { result = result&0x8000 != 0 ? (result<<1)^0x1021 : result<<1 } }
        return result
    }
    public static func nearbyCode(_ serviceName: String) -> String? {
        guard serviceName.hasPrefix("Film-") else { return nil }
        let code = String(serviceName.dropFirst(5))
        return isValidCode(code) ? code : nil
    }
    /// OCR accepts a complete six-digit line, never digits extracted from prose.
    public static func parseCameraDigits(_ text: String) -> String? {
        let code = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return isValidCode(code) ? code : nil
    }
    /// Only our exact marker is accepted. The scanner never follows URLs.
    public static func parseMarker(_ marker:String) -> String? {
        guard marker.hasPrefix("film://pair?code=") else { return nil }
        let code=String(marker.dropFirst("film://pair?code=".count))
        return isValidCode(code) ? code:nil
    }
}
public struct ConsistentLightReadings: Sendable {
    private var previous:String?
    public init() {}
    public mutating func accept(_ code:String?) -> String? {
        guard let code,LightCodeCodec.isValidCode(code) else { previous=nil; return nil }
        defer { previous=code }; return previous==code ? code:nil
    }
    public mutating func reset() { previous=nil }
}
