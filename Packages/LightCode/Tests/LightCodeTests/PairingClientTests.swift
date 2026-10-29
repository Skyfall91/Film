import XCTest
@testable import LightCode
private final class PairingProtocol: URLProtocol, @unchecked Sendable {
 nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int,Data))?
 override class func canInit(with request:URLRequest)->Bool { true }
 override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
 override func startLoading() { do { let (status,data)=try Self.handler!(request); let response=HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:["Content-Type":"application/json"])!; client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed); client?.urlProtocol(self,didLoad:data); client?.urlProtocolDidFinishLoading(self) } catch { client?.urlProtocol(self,didFailWithError:error) } }
 override func stopLoading() {}
}
final class PairingClientTests: XCTestCase {
 private func client() -> PairingClient { let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[PairingProtocol.self];return PairingClient(baseURL:URL(string:"https://film.test")!,publishableKey:"public-test-key",session:URLSession(configuration:config)) }
 func testCreateUsesCamelCaseJSONAndPublicKeyOnly() async throws {
  PairingProtocol.handler={ request in
   XCTAssertEqual(request.url?.path,"/functions/v1/film-device/createPairing");XCTAssertEqual(request.httpMethod,"POST");XCTAssertEqual(request.value(forHTTPHeaderField:"apikey"),"public-test-key");XCTAssertNil(request.value(forHTTPHeaderField:"Authorization"))
   var data=request.httpBody ?? Data()
   if let stream=request.httpBodyStream {stream.open();defer {stream.close()};var buffer=[UInt8](repeating:0,count:4096);while stream.hasBytesAvailable {let count=stream.read(&buffer,maxLength:buffer.count);if count<=0 {break};data.append(contentsOf:buffer.prefix(count))}}
   let json=try JSONSerialization.jsonObject(with:data) as! [String:String];XCTAssertEqual(json,["pollHash":"poll-test","sessionHash":"session-test","deviceName":"Wohnzimmer"])
   return (200,Data(#"{"id":"test-id","code":"012345","expiresAt":"2026-10-15T12:05:00Z"}"#.utf8))
  }
  let result=try await client().createPairing(pollHash:"poll-test",sessionHash:"session-test",deviceName:"Wohnzimmer");XCTAssertEqual(result.code,"012345")
 }
 func testServerFailureDoesNotDecodeAsSuccess() async {
  PairingProtocol.handler={ _ in (429,Data(#"{"error":"rate_limited"}"#.utf8)) }
  do { _=try await client().createPairing(pollHash:"p",sessionHash:"s",deviceName:"TV");XCTFail("Accepted failure") } catch {}
 }
 func testMalformedSuccessIsRejected() async {
  PairingProtocol.handler={ _ in (200,Data(#"{"id":"test-id","code":"not-six-digits","expiresAt":"invalid"}"#.utf8)) }
  do { _=try await client().createPairing(pollHash:"p",sessionHash:"s",deviceName:"TV");XCTFail("Accepted malformed payload") } catch {}
 }
 func testAuthenticatedApprovalBindsSameIDAndCode() async throws {
  PairingProtocol.handler={ request in
   XCTAssertEqual(request.url?.lastPathComponent,"approvePairing")
   XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"),"Bearer iphone-test-jwt")
   var data=request.httpBody ?? Data()
   if let stream=request.httpBodyStream {stream.open();defer {stream.close()};var buffer=[UInt8](repeating:0,count:4096);while stream.hasBytesAvailable {let count=stream.read(&buffer,maxLength:buffer.count);if count<=0 {break};data.append(contentsOf:buffer.prefix(count))}}
   let json=try JSONSerialization.jsonObject(with:data) as! [String:String]
   XCTAssertEqual(json,["id":"request-test-id","code":"012345"])
   return (200,Data(#"{"status":"approved"}"#.utf8))
  }
  let response=try await client().approvePairing(id:"request-test-id",code:"012345",bearerToken:"iphone-test-jwt")
  XCTAssertEqual(response.status,"approved")
 }
 func testRotationRejectsUnconfirmedStatus() async {
  PairingProtocol.handler={ _ in (200,Data(#"{"status":"pending","expiresAt":"2026-10-15T12:05:00Z"}"#.utf8)) }
  do {_ = try await client().rotateSession(newHash:"new-test",operationID:"test-operation",bearerToken:"tv-test");XCTFail("Accepted unconfirmed rotation")} catch {}
 }
 func testRevocationRejectsUnconfirmedStatus() async {
  PairingProtocol.handler={ _ in (200,Data(#"{"status":"active"}"#.utf8)) }
  do {_ = try await client().revokeSession(bearerToken:"tv-test");XCTFail("Accepted unconfirmed revocation")} catch {}
 }

}
