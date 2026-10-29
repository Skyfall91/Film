/// The server derives the namespace from the verified phone principal.
/// Request payloads continue to carry only the locally generated raw identifier.
nonisolated enum PhoneClaimPolicy {
    static func owns(serverClaimant: String?, rawPhoneID: String) -> Bool {
        !rawPhoneID.isEmpty && serverClaimant == "phone:" + rawPhoneID
    }
}
