import Foundation

@main struct PhoneClaimPolicyTests {
    static func main() {
        let phone = "a0ecf659-c197-468a-99b1-5275e4e067c3"
        assert(PhoneClaimPolicy.owns(serverClaimant: "phone:" + phone, rawPhoneID: phone))
        assert(!PhoneClaimPolicy.owns(serverClaimant: phone, rawPhoneID: phone))
        assert(!PhoneClaimPolicy.owns(serverClaimant: "phone:another-device", rawPhoneID: phone))
        assert(!PhoneClaimPolicy.owns(serverClaimant: "tv:" + phone, rawPhoneID: phone))
        assert(!PhoneClaimPolicy.owns(serverClaimant: nil, rawPhoneID: phone))
        assert(!PhoneClaimPolicy.owns(serverClaimant: "phone:", rawPhoneID: ""))
        print("Phone claim policy: 6 assertions passed")
    }
}
