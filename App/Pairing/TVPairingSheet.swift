#if os(iOS)
import SwiftUI
import LightCode

struct TVPairingSheet: View {
    let accountEmail:String
    let initialCode:String?
    let accessToken:() async throws -> String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @StateObject private var camera=PairingCamera()
    @State private var manualCode=""
    @State private var scanning=false
    @State private var request:ResolvedPairing?
    @State private var errorMessage:String?
    @State private var completionMessage:String?
    @State private var busy=false
    @State private var operation:Task<Void,Never>?
    @State private var accountChanged=false
    @State private var visible=false
    private var client:PairingClient {PairingClient(baseURL:CloudAccounts.backendURL,publishableKey:CloudAccounts.pairingPublishableKey)}

    init(accountEmail:String,initialCode:String? = nil,accessToken:@escaping () async throws -> String) {self.accountEmail=accountEmail;self.initialCode=initialCode;self.accessToken=accessToken}
    var body:some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:initialCode == nil ? 20 : 14) {
                    if let completionMessage {
                        Label(completionMessage,systemImage:"checkmark.circle.fill").font(.title2)
                        Text("Der Fernseher übernimmt den Status beim nächsten Abruf.").foregroundStyle(.secondary)
                        Button("Schließen") {dismiss()}.buttonStyle(.borderedProminent)
                    } else if let request {
                        confirmation(request)
                    } else if initialCode != nil, busy {
                        ProgressView("Apple TV wird geprüft …").frame(maxWidth: .infinity, minHeight: 220)
                    } else {
                        Text("Fernseher verbinden").font(.title2.bold())
                        Text("Gib die sechs Ziffern vom Fernseher ein oder scanne den Code.")
                        if scanning {
                        ZStack {
                            PairingCameraPreview(camera:camera).frame(height:260).clipShape(RoundedRectangle(cornerRadius:16))
                            RoundedRectangle(cornerRadius:12).stroke(.white.opacity(0.8),lineWidth:2).frame(width:210,height:210).accessibilityHidden(true)
                        }.accessibilityLabel("Kamera für den Fernsehercode")
                        }
                        if let message=camera.message {Text(message).font(.callout).foregroundStyle(.secondary)}
                        if !scanning {
                            Button("Code scannen", systemImage:"qrcode.viewfinder") { scanning=true;camera.start() }
                        }
                        TextField("Sechsstelliger Code",text:$manualCode).keyboardType(.numberPad).textContentType(.oneTimeCode).font(.title3.monospaced()).onChange(of:manualCode) {_,value in manualCode=String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))}
                        Button("Code prüfen") {resolve(manualCode)}.buttonStyle(.borderedProminent).disabled(!LightCodeCodec.isValidCode(manualCode)||busy||accountChanged)
                        Text("Du bestätigst den Fernseher im nächsten Schritt mit \(accountEmail).").font(.footnote).foregroundStyle(.secondary)
                    }
                    if busy, request != nil || initialCode == nil {ProgressView("Anfrage wird geprüft …")}
                    if let errorMessage {Text(errorMessage).foregroundStyle(.red).accessibilityLabel("Fehler: \(errorMessage)")}
                }.padding()
            }
            .navigationTitle(initialCode == nil ? "Apple TV verbinden" : "Apple TV gefunden")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {ToolbarItem(placement:.cancellationAction) {Button("Schließen") {cancel();dismiss()}}}
            .onAppear {visible=true;if let initialCode {manualCode=initialCode;resolve(initialCode)}}
            .onDisappear {visible=false;cancel()}
            .onChange(of:camera.detectedCode) {_,code in if let code,visible,!busy,request==nil,!accountChanged {resolve(code)}}
            .onChange(of:accountEmail) {_,_ in cancel();request=nil;completionMessage=nil;accountChanged=true;errorMessage="Das Konto hat sich geändert. Schließe den Scanner und öffne ihn mit dem gewünschten Konto erneut."}
        }
        .presentationDetents(initialCode == nil || typeSize.isAccessibilitySize ? [.medium, .large] : [.height(340), .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(32)
    }
    @ViewBuilder private func confirmation(_ pairing:ResolvedPairing) -> some View {
        if initialCode == nil {
            Text("Diesen Fernseher bestätigen?").font(.title2.bold())
            LabeledContent("Gerät",value:pairing.deviceName)
            LabeledContent("Konto",value:accountEmail)
        } else {
            HStack(spacing: 14) {
                Image(systemName: "appletv.fill").font(.title).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(pairing.deviceName).font(.headline)
                    Text(accountEmail).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        Text(pairing.code)
            .font(.system(size: initialCode == nil ? 34 : 38, weight: .semibold, design: .monospaced))
            .tracking(7).frame(maxWidth: .infinity)
            .accessibilityLabel("Code \(pairing.code.map(String.init).joined(separator:" "))")
        Text("Stimmt der Code am Fernseher überein?")
            .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        TimelineView(.periodic(from:.now,by:1)) {timeline in
            let remaining=max(0,Int((PairingClient.date(pairing.expiresAt) ?? .distantPast).timeIntervalSince(timeline.date)))
            Text(remaining>0 ? "Noch \(remaining/60):\(String(format:"%02d",remaining%60)) gültig" : "Code abgelaufen – erstelle am Fernseher einen neuen Code.")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            Button {decide(approve:true)} label: {
                Text("Verbinden").font(.headline).frame(maxWidth: .infinity, minHeight: 36)
            }.buttonStyle(.borderedProminent).disabled(busy||remaining==0||accountChanged)
        }
        Button("Anfrage ablehnen",role:.destructive) {decide(approve:false)}
            .font(.subheadline).frame(maxWidth: .infinity).disabled(busy||accountChanged)
        if initialCode == nil {
            Button("Anderen Code scannen") {operation?.cancel();request=nil;errorMessage=nil;manualCode="";scanning=true;camera.start()}.disabled(busy)
        }
    }
    @MainActor private func resolve(_ code:String) {
        guard visible,!busy,!accountChanged else {return};camera.stop();busy=true;errorMessage=nil
        let email=accountEmail
        operation=Task { @MainActor in
            do {
                let resolved=try await client.resolveCode(code)
                try Task.checkCancellation();guard email==accountEmail,!accountChanged else {return}
                request=resolved;busy=false
            } catch is CancellationError {busy=false}
            catch {busy=false;errorMessage=error.localizedDescription;if visible,!accountChanged,scanning {camera.start()}}
        }
    }
    @MainActor private func decide(approve:Bool) {
        guard let pairing=request,!busy,!accountChanged else {return};busy=true;errorMessage=nil
        let email=accountEmail
        operation=Task { @MainActor in
            do {
                let token=try await accessToken();try Task.checkCancellation()
                guard email==accountEmail,!accountChanged else {busy=false;return}
                if approve {_ = try await client.approvePairing(id:pairing.id,code:pairing.code,bearerToken:token)}
                else {_ = try await client.rejectPairing(id:pairing.id,code:pairing.code,bearerToken:token)}
                try Task.checkCancellation();guard email==accountEmail,!accountChanged else {busy=false;return}
                request=nil;busy=false;completionMessage=approve ? "Fernseher bestätigt":"Anfrage abgelehnt"
            } catch is CancellationError {busy=false}
            catch {busy=false;errorMessage=error.localizedDescription}
        }
    }
    @MainActor private func cancel() {operation?.cancel();operation=nil;camera.stop();busy=false}
}

/// Bonjour is a hint only. The server resolves the code and the person still
/// compares/approves it. Never trust a service name as proof of device identity.
@MainActor final class NearbyTVDiscovery: NSObject, ObservableObject, @preconcurrency NetServiceBrowserDelegate {
    @Published private(set) var codes: [String] = []
    private var browser: NetServiceBrowser?
    private var services: [NetService] = []
    func start() {
        guard browser == nil else { return }
        let browser = NetServiceBrowser()
        browser.delegate = self
        self.browser = browser
        browser.searchForServices(ofType: "_film-pair._tcp.", inDomain: "local.")
    }
    func stop() {
        browser?.stop(); browser?.delegate = nil; browser = nil
        services = []; codes = []
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard browser === self.browser, LightCodeCodec.nearbyCode(service.name) != nil else { return }
        if !services.contains(where: { $0.name == service.name && $0.domain == service.domain }) { services.append(service) }
        updateCodes()
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        guard browser === self.browser else { return }
        services.removeAll { $0.name == service.name && $0.domain == service.domain }
        updateCodes()
    }
    private func updateCodes() {
        codes = Array(Set(services.compactMap { LightCodeCodec.nearbyCode($0.name) })).sorted()
    }
}

struct NearbyTVPairingPrompt: ViewModifier {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var phase
    @StateObject private var discovery = NearbyTVDiscovery()
    @State private var dismissed: Set<String> = []
    @State private var selected: NearbyRequest?
    private struct NearbyRequest: Identifiable {
        let id: String
    }
    func body(content: Content) -> some View {
        content
            .sheet(item: $selected, onDismiss: {}) { request in
                TVPairingSheet(accountEmail: store.account?.email ?? "", initialCode: request.id,
                               accessToken: { try await store.currentPhoneSessionToken() })
                    .onDisappear { dismissed.insert(request.id) }
            }
            .onChange(of: discovery.codes) { _, codes in
                guard selected == nil, phase == .active, store.signedIn, store.account != nil,
                      let code = codes.first(where: { !dismissed.contains($0) }) else { return }
                dismissed.insert(code)
                selected = NearbyRequest(id: code)
            }
            .onAppear { updateDiscovery() }
            .onDisappear { discovery.stop() }
            .onChange(of: phase) { _, _ in updateDiscovery() }
            .onChange(of: store.signedIn) { _, _ in updateDiscovery() }
            .onChange(of: store.account?.email) { _, _ in
                discovery.stop(); selected = nil; dismissed = []; updateDiscovery()
            }
    }
    private func updateDiscovery() {
        if phase == .active, store.signedIn, store.account != nil { discovery.start() }
        else { discovery.stop() }
    }
}

#endif
