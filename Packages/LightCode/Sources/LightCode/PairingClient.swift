import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum PairingClientError: LocalizedError, Sendable {
    case invalidEndpoint, invalidCode, invalidResponse, server(status:Int,code:String)
    public var errorDescription:String? {
        switch self {
        case .invalidEndpoint: return "Der Kopplungsdienst ist nicht sicher konfiguriert."
        case .invalidCode: return "Bitte gib genau sechs Ziffern ein."
        case .invalidResponse: return "Der Kopplungsdienst hat eine ungültige Antwort gesendet."
        case .server(let status,let code):
            if status==429 { return "Zu viele Versuche. Bitte warte eine Minute und versuche es erneut." }
            if status==401 || status==403 { return "Die Anmeldung ist abgelaufen. Bitte melde dich erneut an." }
            if code.contains("expired") { return "Der Code ist abgelaufen. Erstelle am Fernseher einen neuen Code." }
            return "Die Anfrage konnte nicht abgeschlossen werden (\(status))."
        }
    }
}
public struct PairingRequest: Codable, Sendable { public let id:String; public let code:String; public let expiresAt:String }
public struct ResolvedPairing: Codable, Sendable, Identifiable { public let id:String; public let code:String; public let deviceName:String; public let expiresAt:String; public let status:String }
public struct PairingStatusResponse: Codable, Sendable { public let status:String }
public struct PairingActivation: Codable, Sendable { public let status:String; public let userID:String?; public let email:String?; public let expiresAt:String? }
public struct PairingRotation: Codable, Sendable { public let status:String; public let expiresAt:String? }

/// The public key is not a user credential. iPhone JWTs and dedicated TV tokens
/// travel only in the Authorization header and are never stored by this client.
public final class PairingClient: @unchecked Sendable {
    private let baseURL:URL
    private let publishableKey:String
    private let session:URLSession
    public init(baseURL:URL,publishableKey:String,session:URLSession = .shared) { self.baseURL=baseURL;self.publishableKey=publishableKey;self.session=session }
    public func createPairing(pollHash:String,sessionHash:String,deviceName:String) async throws -> PairingRequest {
        struct Body:Encodable { let pollHash:String;let sessionHash:String;let deviceName:String }
        let result:PairingRequest=try await post(route:"createPairing",body:Body(pollHash:pollHash,sessionHash:sessionHash,deviceName:deviceName),as:PairingRequest.self)
        guard !result.id.isEmpty,LightCodeCodec.isValidCode(result.code),Self.date(result.expiresAt) != nil else { throw PairingClientError.invalidResponse };return result
    }
    public func resolveCode(_ code:String) async throws -> ResolvedPairing {
        guard LightCodeCodec.isValidCode(code) else { throw PairingClientError.invalidCode }
        struct Body:Encodable {let code:String}
        let result:ResolvedPairing=try await post(route:"resolveCode",body:Body(code:code),as:ResolvedPairing.self)
        guard !result.id.isEmpty,result.code==code,!result.deviceName.isEmpty,result.status=="pending",Self.date(result.expiresAt) != nil else {throw PairingClientError.invalidResponse};return result
    }
    public func approvePairing(id:String,code:String,bearerToken:String) async throws -> PairingStatusResponse {try await decision("approvePairing",id:id,code:code,bearerToken:bearerToken)}
    public func rejectPairing(id:String,code:String,bearerToken:String) async throws -> PairingStatusResponse {try await decision("rejectPairing",id:id,code:code,bearerToken:bearerToken)}
    private func decision(_ route:String,id:String,code:String,bearerToken:String) async throws -> PairingStatusResponse {
        guard LightCodeCodec.isValidCode(code),!id.isEmpty,!bearerToken.isEmpty else {throw PairingClientError.invalidCode}
        struct Body:Encodable {let id:String;let code:String}
        let result:PairingStatusResponse=try await post(route:route,body:Body(id:id,code:code),bearerToken:bearerToken,as:PairingStatusResponse.self)
        guard result.status==(route=="approvePairing" ? "approved":"rejected") else {throw PairingClientError.invalidResponse};return result
    }
    public func activateSession(id:String,pollSecret:String) async throws -> PairingActivation {
        struct Body:Encodable {let id:String;let pollSecret:String}
        let result:PairingActivation=try await post(route:"activateSession",body:Body(id:id,pollSecret:pollSecret),as:PairingActivation.self)
        guard ["pending","approved","active","activated","rejected","expired","cancelled"].contains(result.status) else {throw PairingClientError.invalidResponse}
        if ["active","activated"].contains(result.status) {guard let user=result.userID,!user.isEmpty,let expiry=result.expiresAt,Self.date(expiry) != nil else {throw PairingClientError.invalidResponse}}
        return result
    }
    public func rotateSession(newHash:String,operationID:String,bearerToken:String) async throws -> PairingRotation {
        struct Body:Encodable {let newHash:String;let operationID:String}
        let result:PairingRotation=try await post(route:"rotateSession",body:Body(newHash:newHash,operationID:operationID),bearerToken:bearerToken,as:PairingRotation.self)
        guard result.status=="rotated",let expiry=result.expiresAt,Self.date(expiry) != nil else {throw PairingClientError.invalidResponse};return result
    }
    public func revokeSession(bearerToken:String,id:String? = nil) async throws -> PairingStatusResponse {
        struct Body:Encodable {let id:String?}
        let result:PairingStatusResponse=try await post(route:"revokeSession",body:Body(id:id),bearerToken:bearerToken,as:PairingStatusResponse.self)
        guard result.status=="revoked" else {throw PairingClientError.invalidResponse};return result
    }
    public func post<Request:Encodable,Response:Decodable>(route:String,body:Request,bearerToken:String? = nil,as:Response.Type) async throws -> Response {
        let data=try await postData(route:route,body:JSONEncoder().encode(body),bearerToken:bearerToken)
        do {return try JSONDecoder().decode(Response.self,from:data)} catch {throw PairingClientError.invalidResponse}
    }
    public func postData(route:String,body:Data,bearerToken:String? = nil) async throws -> Data {
        guard baseURL.scheme=="https",baseURL.host != nil,baseURL.user==nil,baseURL.password==nil,route.range(of:"^[A-Za-z]+$",options:.regularExpression) != nil else {throw PairingClientError.invalidEndpoint}
        var request=URLRequest(url:baseURL.appendingPathComponent("functions/v1/film-device").appendingPathComponent(route))
        request.httpMethod="POST";request.timeoutInterval=20;request.httpBody=body
        request.setValue("application/json",forHTTPHeaderField:"Content-Type");request.setValue("application/json",forHTTPHeaderField:"Accept");request.setValue(publishableKey,forHTTPHeaderField:"apikey")
        if let token=bearerToken {guard !token.isEmpty,!token.contains("\n"),!token.contains("\r") else {throw PairingClientError.invalidResponse};request.setValue("Bearer \(token)",forHTTPHeaderField:"Authorization")}
        let (data,response)=try await session.data(for:request)
        guard let http=response as? HTTPURLResponse else {throw PairingClientError.invalidResponse}
        guard (200..<300).contains(http.statusCode) else {
            let object=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any]
            let code=(object?["error"] as? String) ?? "server_error"
            throw PairingClientError.server(status:http.statusCode,code:code)
        }
        guard data.count<=8_000_000 else {throw PairingClientError.invalidResponse};return data
    }
    public static func date(_ string:String) -> Date? {let formatter=ISO8601DateFormatter();formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds];return formatter.date(from:string) ?? ISO8601DateFormatter().date(from:string)}
}
