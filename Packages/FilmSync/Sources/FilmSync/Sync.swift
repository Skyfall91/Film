import Foundation
public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    public var array:[JSONValue]?{if case .array(let v)=self{return v};return nil}
    public subscript(_ key:String)->JSONValue?{if case .object(let v)=self{return v[key]};return nil}
    public init(from decoder:any Decoder)throws{let c=try decoder.singleValueContainer();if c.decodeNil(){self = .null}else if let v=try? c.decode(Bool.self){self = .bool(v)}else if let v=try? c.decode(Double.self){self = .number(v)}else if let v=try? c.decode(String.self){self = .string(v)}else if let v=try? c.decode([JSONValue].self){self = .array(v)}else{self = .object(try c.decode([String:JSONValue].self))}}
    public func encode(to encoder:any Encoder)throws{var c=encoder.singleValueContainer();switch self{case .object(let v):try c.encode(v);case .array(let v):try c.encode(v);case .string(let v):try c.encode(v);case .number(let v):try c.encode(v);case .bool(let v):try c.encode(v);case .null:try c.encodeNil()}}
    public static func parse(_ text:String)throws->JSONValue{try JSONDecoder().decode(JSONValue.self,from:Data(text.utf8))}
}
public struct SyncOperation: Codable,Equatable,Sendable,Identifiable{
    public var id:UUID;public var kind:String;public var profileID:String?;public var filmID:String?;public var payload:JSONValue
    public init(id:UUID=UUID(),kind:String,profileID:String?=nil,filmID:String?=nil,payload:JSONValue){self.id=id;self.kind=kind;self.profileID=profileID;self.filmID=filmID;self.payload=payload}
}
extension JSONValue {
    public var object:[String:JSONValue]? { if case .object(let x)=self{return x};return nil }
    public var string:String? { if case .string(let x)=self{return x};return nil }
    public var number:Double? { if case .number(let x)=self{return x};return nil }
    /// Über JSONSerialization statt Decodable: Der Decodable-Weg probiert für jeden Wert nacheinander
    /// Bool, Zahl, Text, Liste und Objekt und wirft bei jedem Fehlversuch, bei einem ganzen Kontostand
    /// sind das zehntausende Fehler pro Abgleich.
    public static func decode(_ data:Data)throws->JSONValue {
        try JSONValue(foundation: JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }
    init(foundation value: Any) throws {
        switch value {
        case let d as [String: Any]: self = .object(try d.mapValues { try JSONValue(foundation: $0) })
        case let a as [Any]: self = .array(try a.map { try JSONValue(foundation: $0) })
        case let s as String: self = .string(s)
        case let n as NSNumber:
            self = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
        case is NSNull: self = .null
        default: throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unbekannter JSON-Wert"))
        }
    }
    public func data()throws->Data {try JSONEncoder().encode(self)}
}

public enum SnapshotChanges {
    public static func operations(from old:JSONValue,to new:JSONValue)->[SyncOperation] {
        var result:[SyncOperation]=[]
        func add(_ kind:String,_ id:String?=nil,_ film:String?=nil,_ payload:[String:JSONValue]=[:]) {
            result.append(SyncOperation(kind:kind,profileID:id,filmID:film,payload:.object(payload)))
        }
        let previous=profiles(old),current=profiles(new)
        for id in previous.keys.sorted() where current[id]==nil {add("profileDelete",id)}
        for id in current.keys.sorted() {
            guard let after=current[id] else {continue}
            guard let before=previous[id] else {add("profileCreate",id,nil,["profile":after]);continue}
            var fields:[String:JSONValue]=[:]
            for key in ["name","colorIndex","maxFSK","littleKid","avatar","onboardingComplete"] where after[key] != before[key] {
                fields[key]=after[key] ?? .null
            }
            let countDelta=(after["importedCount"]?.number ?? 0)-(before["importedCount"]?.number ?? 0)
            if countDelta != 0 {fields["importedCountDelta"] = .number(countDelta)}
            if after["external"] != before["external"], let external=after["external"] {fields["external"]=external}
            let oldRatings=before["interactions"]?.object ?? [:],newRatings=after["interactions"]?.object ?? [:]
            var learning=learningDelta(before,after)
            let oldExternal=before["external"]?.object ?? [:],newExternal=after["external"]?.object ?? [:]
            let externalIDs=Set(oldExternal.keys).union(newExternal.keys)
            let changedRatings=Set(oldRatings.keys).union(newRatings.keys).filter {oldRatings[$0] != newRatings[$0]}
            // Repeated actions can change learning while preserving the stored
            // enum value. notToday intentionally does not store an interaction.
            let changedSamples=(learning["samples"]?.array ?? []).compactMap {$0["filmID"]?.string}
            var ratingFilms=Set(changedRatings).union(changedSamples).subtracting(externalIDs)
            if ratingFilms.isEmpty,changedSamples.isEmpty,!learning.isEmpty {
                let existingRatings=Set(oldRatings.keys).union(newRatings.keys).subtracting(externalIDs).sorted()
                let existingSamples=(before["samples"]?.array ?? [])+(after["samples"]?.array ?? [])
                let sampleIDs=Set(existingSamples.compactMap {$0["filmID"]?.string}).subtracting(externalIDs).sorted()
                if let carrier=existingRatings.first ?? sampleIDs.first {ratingFilms.insert(carrier)}
            }
            if ratingFilms.isEmpty,!learning.isEmpty {
                // External imports have no playable catalog title to carry a
                // rating. Keep their learning with their profile metadata.
                learning["samples"] = learning["samples"] ?? .array([])
                fields["learning"] = .object(learning)
            }
            // Metadata must precede mixed learning so external sample IDs are
            // already known when the first catalog rating arrives at the server.
            if !fields.isEmpty {add("profileUpdate",id,nil,fields)}
            let oldList=Set((before["watchlist"]?.array ?? []).compactMap(\.string)),newList=Set((after["watchlist"]?.array ?? []).compactMap(\.string))
            for film in newList.subtracting(oldList).sorted(){add("watchlistAdd",id,film)}
            for film in oldList.subtracting(newList).sorted(){add("watchlistRemove",id,film)}
            for (index,film) in ratingFilms.sorted().enumerated() {
                var payload:[String:JSONValue]=["rating":newRatings[film] ?? .null]
                if index==0 {
                    // Presence of samples, including an empty array, marks
                    // native learning and prevents server-derived extra samples.
                    learning["samples"] = learning["samples"] ?? .array([])
                    payload["learning"] = .object(learning)
                } else {
                    // A persisted outbox may be split into multiple requests.
                    // Each later rating must also suppress legacy derivation.
                    payload["learning"] = .object(["samples":.array([])])
                }
                add("ratingSet",id,film,payload)
            }
            let oldHints=before["hints"]?.object ?? [:],newHints=after["hints"]?.object ?? [:]
            for key in Set(oldHints.keys).union(newHints.keys).sorted() {
                let delta=(newHints[key]?.number ?? 0)-(oldHints[key]?.number ?? 0)
                if delta != 0 {add("hintSet",id,nil,["key":.string(key),"value":.number(delta)])}
            }
            let oldReviews=reviews(before),newReviews=reviews(after)
            for film in Set(oldReviews.keys).union(newReviews.keys).sorted() where oldReviews[film] != newReviews[film] {
                add("reviewSet",id,film,["review":newReviews[film] ?? .null])
            }
            let oldProgress=before["progress"]?.object ?? [:],newProgress=after["progress"]?.object ?? [:]
            for film in Set(oldProgress.keys).union(newProgress.keys).sorted() where oldProgress[film] != newProgress[film] {
                add("progressSet",id,film,["progress":newProgress[film] ?? .null])
            }
            let oldPositions=before["playbackPositions"]?.object ?? [:],newPositions=after["playbackPositions"]?.object ?? [:]
            for key in Set(oldPositions.keys).union(newPositions.keys).sorted() where oldPositions[key] != newPositions[key] {
                let film=key.split(separator:"|").first.map(String.init) ?? key
                add("progressSet",id,film,["positionKey":.string(key),"seconds":newPositions[key] ?? .number(0)])
            }
        }
        let previousOrder=(old["profiles"]?.array ?? []).compactMap {$0["id"]?.string?.lowercased()}
        let currentOrder=(new["profiles"]?.array ?? []).compactMap {$0["id"]?.string?.lowercased()}
        let retainedIDs=Set(previous.keys).intersection(current.keys)
        if previousOrder.filter({retainedIDs.contains($0)}) != currentOrder.filter({retainedIDs.contains($0)}) {
            // Creation/deletion are already queued. Order is an explicit CAS
            // mutation and never carries local viewer selections or profile data.
            add("profileOrder",nil,nil,["profileIDs":.array(currentOrder.map(JSONValue.string))])
        }
        let subscription=new["account"]?["subscription"]
        if old["account"]?["subscription"] != subscription,subscription?["source"]?.string != "appStore" {
            // StoreKit grants come only from the separate Apple JWS verifier.
            // Enqueuing an unverified client grant would block unrelated edits.
            add("subscriptionSet",nil,nil,["subscription":subscription ?? .null])
        }
        let previousPending=pending(old),currentPending=pending(new)
        for id in previousPending.keys.sorted() where currentPending[id]==nil {add("pendingRatingRemove",nil,nil,["id":.string(id)])}
        for id in currentPending.keys.sorted() where previousPending[id] != currentPending[id] {add("pendingRatingSet",nil,nil,["pending":currentPending[id]!])}
        return result
    }
    private static func profiles(_ state:JSONValue)->[String:JSONValue] {
        var result:[String:JSONValue]=[:]
        for profile in state["profiles"]?.array ?? [] {if let id=profile["id"]?.string {result[id.lowercased()]=profile}}
        return result
    }
    private static func reviews(_ profile:JSONValue)->[String:JSONValue] {
        var result:[String:JSONValue]=[:]
        for review in profile["reviews"]?.array ?? [] {if let id=review["filmID"]?.string {result[id]=review}}
        return result
    }
    private static func pending(_ state:JSONValue)->[String:JSONValue] {
        var result:[String:JSONValue]=[:]
        for value in state["pendingRatings"]?.array ?? [] {
            let film=value["filmID"]?.string ?? ""
            let date=(try? value["date"]?.data()).flatMap{String(data:$0,encoding:.utf8)} ?? ""
            result[film+"|"+date]=value
        }
        return result
    }
    private static func learningDelta(_ old:JSONValue,_ new:JSONValue)->[String:JSONValue] {
        var result:[String:JSONValue]=[:]
        for field in ["affinity","exposure"] {
            let a=old[field]?.object ?? [:],b=new[field]?.object ?? [:]
            var deltas:[String:JSONValue]=[:]
            for key in Set(a.keys).union(b.keys) {
                var delta=(b[key]?.number ?? 0)-(a[key]?.number ?? 0)
                if field=="affinity" {
                    // hintSet applies its own affinity change. Carry only the
                    // rating contribution here, so mixed edits learn once.
                    delta -= (new["hints"]?[key]?.number ?? 0)-(old["hints"]?[key]?.number ?? 0)
                }
                if delta != 0 {deltas[key] = .number(delta)}
            }
            if !deltas.isEmpty {result[field] = .object(deltas)}
        }
        for field in ["signalTotal","signalN"] {let d=(new[field]?.number ?? 0)-(old[field]?.number ?? 0);if d != 0 {result[field] = .number(d)}}
        func targets(_ profile:JSONValue)->[String:Double] {
            var values:[String:Double]=[:]
            for sample in profile["samples"]?.array ?? [] {if let id=sample["filmID"]?.string {values[id]=sample["target"]?.number ?? 0}}
            return values
        }
        let a=targets(old),b=targets(new)
        let samples=Set(a.keys).union(b.keys).sorted().compactMap {key->JSONValue? in
            let delta=(b[key] ?? 0)-(a[key] ?? 0)
            return delta==0 ? nil:.object(["filmID":.string(key),"delta":.number(delta)])
        }
        if !samples.isEmpty {result["samples"] = .array(samples)}
        return result
    }
}
