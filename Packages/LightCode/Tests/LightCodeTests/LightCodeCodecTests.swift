import XCTest
@testable import LightCode
final class LightCodeCodecTests: XCTestCase {
 func testNearbyServiceNamesAcceptOnlyOurExactCode() {
  XCTAssertEqual(LightCodeCodec.nearbyCode("Film-001234"), "001234")
  for name in ["001234", "Film-12345", "Film-１２３４５６", "Film-123456 (2)", "Other-123456"] {
   XCTAssertNil(LightCodeCodec.nearbyCode(name))
  }
 }

 func testCameraDigitsAreStrictAndKeepLeadingZeroes() {
  XCTAssertEqual(LightCodeCodec.parseCameraDigits(" 001234\n"), "001234")
  for text in ["12345", "1234567", "12 3456", "１２３４５６", "Code: 123456", "1:23", "12345O"] {
   XCTAssertNil(LightCodeCodec.parseCameraDigits(text))
  }
 }

 func testFullSixDigitsFitOneFrameIncludingLeadingZeroes() throws {
  for code in ["000000", "000001", "019284", "999999", "582601"] { XCTAssertEqual(LightCodeCodec.decode(try LightCodeCodec.encode(code)), code) }
 }
 func testInvalidCodesAreRejected() { for code in ["123", "1000000", "１２３４５６", "-12345", "12x456"] { XCTAssertThrowsError(try LightCodeCodec.encode(code)) } }
 func testRotationPreservesFullPayload() throws {
  var frame = try LightCodeCodec.encode("219047")
  for _ in 0..<4 { XCTAssertEqual(LightCodeCodec.decode(frame), "219047"); let previous=frame; frame=(0..<144).map { previous[(11-($0%12))*12+($0/12)] } }
 }
 func testCalibrationToleratesBrightnessAndWhiteBalance() throws {
  let frame=try LightCodeCodec.encode("729184").map { LightColor($0.red*0.72+0.08,$0.green*0.68+0.06,$0.blue*0.8+0.04) }
  XCTAssertEqual(LightCodeCodec.decode(frame), "729184")
 }
 func testRedundancyAndIntegrityRejectCorruption() throws {
  var frame=try LightCodeCodec.encode("123456")
  guard frame.count == 144 else { XCTFail("Missing frame"); return }
  frame[13]=frame[14]; XCTAssertNil(LightCodeCodec.decode(frame))
  var other=try LightCodeCodec.encode("123456"); other[13]=LightColor(0.5,0.5,0.5); XCTAssertNil(LightCodeCodec.decode(other))
 }
 func testOrientationAndReferenceColorsAreRequired() throws {
  var frame=try LightCodeCodec.encode("321654"); guard frame.count==144 else { XCTFail("Missing frame"); return }; frame[0]=frame[11]; XCTAssertNil(LightCodeCodec.decode(frame))
 }
 func testTwoConsecutiveCompleteReadingsRequired() {
  var readings=ConsistentLightReadings(); XCTAssertNil(readings.accept("123456")); XCTAssertNil(readings.accept(nil)); XCTAssertNil(readings.accept("123456")); XCTAssertEqual(readings.accept("123456"),"123456"); XCTAssertNil(readings.accept("654321")); XCTAssertEqual(readings.accept("654321"),"654321")
 }
 func testQRMarkerRejectsArbitraryNavigationAndExtraParameters() {
  XCTAssertEqual(LightCodeCodec.parseMarker("film://pair?code=012345"),"012345")
  for marker in ["https://example.org?code=123456", "film://other?code=123456", "film://pair?code=123456&url=https://evil.test", "film://pair?code=12345", "film://pair?code=123456#x", "film://pair/path?code=123456"] { XCTAssertNil(LightCodeCodec.parseMarker(marker)) }
 }
 func testCRCRejectsCorruptedBitEvenWithIntactInversePair() throws {
  var frame=try LightCodeCodec.encode("123456")
  frame.swapAt(31,32)
  XCTAssertNil(LightCodeCodec.decode(frame))
 }
 func testAllBitsAndBoundaryValuesRoundTrip() throws {
  for value in stride(from:0,through:999999,by:977) {
   let code=String(format:"%06d",value)
   XCTAssertEqual(LightCodeCodec.decode(try LightCodeCodec.encode(code)),code)
  }
 }

}
