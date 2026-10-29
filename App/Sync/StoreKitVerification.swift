import Foundation
import LightCode

extension AppStore {
    /// The backend verifies the canonical Apple transaction, derives entitlement
    /// fields and persists its revision. The regular sync coordinator adopts the
    /// resulting state so this request cannot overwrite an in-flight outbox.
    @MainActor func verifyStoreKitEntitlement() async throws {
        guard signedIn,let email=account?.email else {throw AuthError.noAccount}
        guard let signedTransaction=purchases.signedTransaction,!signedTransaction.isEmpty else {
            throw AuthError.server("Für dieses Abo liegt noch kein bestätigter App-Store-Beleg vor. Stelle die Käufe erneut wieder her.")
        }
        let epoch=sessionEpoch
        // Preserve earlier user edits before the verifier creates a revision.
        try await syncNow()
        try Task.checkCancellation()
        guard signedIn,sessionEpoch==epoch,account?.email==email else {throw CancellationError()}
        let bearer:String
        #if os(tvOS)
        guard let credential=TVSessionStore.load(),credential.email==email else {throw AuthError.wrongCredentials}
        bearer=credential.token
        #else
        bearer=try await currentPhoneSessionToken()
        #endif
        try Task.checkCancellation()
        guard signedIn,sessionEpoch==epoch,account?.email==email else {throw CancellationError()}
        nonisolated struct Body:Encodable,Sendable {let signedTransaction:String}
        let client=PairingClient(baseURL:CloudAccounts.backendURL,publishableKey:CloudAccounts.pairingPublishableKey)
        let reply:CloudStateReply=try await client.post(route:"verifySubscription",body:Body(signedTransaction:signedTransaction),bearerToken:bearer,as:CloudStateReply.self)
        try Task.checkCancellation()
        guard signedIn,sessionEpoch==epoch,account?.email==email,reply.email==email,reply.revision>=0 else {throw CancellationError()}
        #if os(tvOS)
        guard reply.userID.lowercased()==credential.userID.lowercased() else {throw CancellationError()}
        #endif
        try await refreshCloudState()
    }
}
