import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

enum TVTheme {
    static let background = Theme.background
    static let muted = Color(red: 0.60, green: 0.66, blue: 0.76)
}

struct TVPosterView: View {
    let film: Film
    var width: CGFloat = 210
    var height: CGFloat = 315

    var body: some View {
        PosterView(film: film, cornerRadius: 16, badgeScale: 1.6)
            .frame(width: width, height: height)
            .accessibilityHidden(true)
    }
}

struct TVAvatarView: View {
    let profile: Profile
    var size: CGFloat = 110

    var body: some View {
        AvatarView(profile: profile, size: size)
    }
}

struct TVScreen<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    var filmHeading = false
    var showsHeading = true
    var backdropFilm: Film? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if showsHeading { VStack(alignment: .leading, spacing: 12) {
                    Text(title).font(filmHeading ? Theme.filmTitle(size: 48) : .system(size: 46, weight: .bold))
                    if let subtitle { Text(subtitle).font(.system(size: 24)).foregroundStyle(.secondary) }
                } }
                content()
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 70).padding(.vertical, 40)
        }.presentationSizing(.page)
        .background { if let backdropFilm { BlurredBackdrop(film: backdropFilm) } else { TVTheme.background } }
    }
}

struct TVFilmGrid: View {
    let films: [Film]
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 225), spacing: 32)], alignment: .leading, spacing: 40) {
            ForEach(films) { film in
                NavigationLink { TVFilmDetailsView(film: film) } label: {
                    VStack(alignment: .leading, spacing: 12) {
                        TVPosterView(film: film)
                        Text(film.title).font(.system(size: 25, weight: .semibold)).lineLimit(2).frame(width: 210, height: 64, alignment: .topLeading)
                        Text(film.isSeries ? "Serie · \(film.yearText)" : "\(film.yearText) · \(film.runtimeText)")
                            .font(.system(size: 20)).foregroundStyle(.secondary).lineLimit(2).frame(width: 210, height: 50, alignment: .topLeading)
                    }.padding(10)
                }.buttonStyle(.card)
            }
        }
    }
}

struct TVEmptyState: View {
    let title: String
    let message: String
    var symbol: String = "film"
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: symbol).font(.system(size: 70)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 36, weight: .bold))
            Text(message).font(.system(size: 26)).foregroundStyle(.secondary).frame(maxWidth: 850, alignment: .leading)
        }.padding(.vertical, 35)
    }
}

struct TVCompanionRequest: Identifiable {
    let id = UUID()
    let kind: String
    let title: String
    var profileID: UUID? = nil
    var filmID: String? = nil
    var payload: String? = nil
}

struct TVCompanionView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: TVCompanionModel
    let request: TVCompanionRequest

    init(store: AppStore, request: TVCompanionRequest) {
        self.request = request
        _model = State(initialValue: TVCompanionModel(store: store))
    }

    var body: some View {
        HStack(spacing: 90) {
            VStack(alignment: .leading, spacing: 28) {
                Text(request.title).font(.system(size: 48, weight: .bold))
                Text("Öffne auf dem angemeldeten iPhone den Bereich „Fernseher“ und wähle diesen Auftrag in der Liste der offenen TV-Aufträge.")
                    .font(.system(size: 26)).foregroundStyle(.secondary)
                Text("Das iPhone zeigt den Auftrag und das betroffene Profil vor der Bestätigung. Nach Abschluss wird das Ergebnis hier übernommen. Es wird kein Scanner für diesen Auftrag benötigt.")
                    .font(.system(size: 24)).foregroundStyle(.secondary)
                if request.kind == "deleteAccount" {
                    Text("Dabei werden das Konto, alle Profile, Bewertungen und Merklisten gelöscht und alle TV-Zugänge widerrufen. Die endgültige Bestätigung erfolgt auf deinem iPhone.").foregroundStyle(.red)
                }
                if request.kind == "mood" {
                    Text("Ohne unterstützte KI bleiben die Stimmungsfilter und die Stichwortsuche auf dem TV verfügbar.").font(.caption)
                }
                Button("Schließen") { dismiss() }
            }.frame(maxWidth: 720)
            VStack(spacing: 24) {
                if let code = model.code {
                    HStack(spacing: 28) {
                        LightCodeView(code: code, showsDetails: false).frame(width: 220, height: 220)
                        TVQRCodeView(code: code).frame(width: 150, height: 150)
                    }
                    Text(code).font(.system(size: 54, weight: .medium, design: .monospaced))
                } else { Image(systemName: "iphone").font(.system(size: 100)).frame(height: 200) }
                Text(model.status).font(.headline).multilineTextAlignment(.center)
                if let error = model.error { Text(error).foregroundStyle(.red).font(.caption) }
                Button("Status prüfen") { Task { await model.refresh() } }
                Button("Neuer Auftrag") { Task { await start() } }
                if model.waiting { Button("Auftrag abbrechen") { Task { await model.cancel() } } }
            }.frame(width: 450)
        }.padding(80).background(TVTheme.background)
        .task { await start() }
    }

    private func start() async {
        await model.start(kind: request.kind, profileID: request.profileID, filmID: request.filmID, payload: request.payload)
    }
}


struct TVQRCodeView: View {
    let code: String
    private var image: UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data("film://pair?code=\(code)".utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let bitmap = CIContext().createCGImage(output.transformed(by: CGAffineTransform(scaleX: 10, y: 10)), from: output.extent.applying(CGAffineTransform(scaleX: 10, y: 10))) else { return nil }
        return UIImage(cgImage: bitmap)
    }
    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().interpolation(.none).scaledToFit().padding(14).background(.white)
            }
        }.accessibilityLabel("QR-Code für Auftrag \(code)")
    }
}

private struct FilmPrimaryAction: ViewModifier {
    @Environment(AppStore.self) private var store
    func body(content: Content) -> some View {
        content.buttonStyle(.glassProminent).tint(store.accent).foregroundStyle(.black)
    }
}
extension View {
    func filmPrimaryAction() -> some View { modifier(FilmPrimaryAction()) }
}

/// The phone's cover composition, with TV-readable type and no touch gesture.
struct TVRecommendationCover: View {
    let recommendation: Recommendation
    let viewers: Int
    var body: some View {
        let film = recommendation.film
        PosterView(film: film, cornerRadius: 28, badgeScale: 1.5)
            .overlay(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Text(viewers > 1 ? "\(recommendation.match) % für euch" : "\(recommendation.match) % Match")
                            .font(.system(size: 22, weight: .heavy)).foregroundStyle(Color.match(recommendation.match))
                        Text(film.isSeries ? "\(film.yearText) · \(film.seasonsText)" : "\(film.yearText) · \(film.runtimeText)")
                            .font(.system(size: 21)).foregroundStyle(.white.opacity(0.75))
                    }.lineLimit(1).minimumScaleFactor(0.85)
                    Text(film.title).font(Theme.recommendationTitle(size: 44)).lineLimit(2)
                    Text(film.hook).font(.system(size: 23)).foregroundStyle(.white.opacity(0.88)).lineLimit(3)
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .padding(26).padding(.top, 70)
                    .background { LinearGradient(colors: [.clear, .black.opacity(0.78), .black.opacity(0.96)], startPoint: .top, endPoint: .bottom) }
            }
            .frame(width: 390, height: 585)
            .clipShape(.rect(cornerRadius: 28))
            .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(.white.opacity(0.12)))
            .accessibilityElement(children: .combine)
    }
}

/// A single focus target for the film, independent of SwiftUI button navigation.
/// Indirect pan events from the Siri Remote preview before an action commits.
struct TVFilmRemoteInput: UIViewControllerRepresentable {
    var enabled: Bool
    var preview: (CGSize) -> Void
    var action: (TVFilmRemoteAction) -> Void
    var focusChanged: (Bool) -> Void

    func makeUIViewController(context: Context) -> TVFilmRemoteController { TVFilmRemoteController() }
    func updateUIViewController(_ controller: TVFilmRemoteController, context: Context) {
        let surface = controller.surface
        surface.preview = preview
        surface.action = action
        surface.focusChanged = focusChanged
        surface.inputEnabled = enabled
    }
}

final class TVFilmRemoteController: UIViewController {
    let surface = TVFilmRemoteSurface()
    override func loadView() { view = surface }
    override var preferredFocusEnvironments: [UIFocusEnvironment] { surface.inputEnabled ? [surface] : [] }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if surface.inputEnabled { setNeedsFocusUpdate(); updateFocusIfNeeded(); surface.requestFilmFocus() }
    }
}


final class TVFilmRemoteSurface: UIView {
    var preview: (CGSize) -> Void = { _ in }
    var action: (TVFilmRemoteAction) -> Void = { _ in }
    var focusChanged: (Bool) -> Void = { _ in }
    private var lastReportedFocus = false
    var inputEnabled = false {
        didSet {
            guard oldValue != inputEnabled else { return }
            if inputEnabled { requestFilmFocus() }
            else { setNeedsFocusUpdate(); updateFocusIfNeeded() }
        }
    }
    override var canBecomeFocused: Bool { inputEnabled }
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityLabel = "Filmcover. Klicken zum Abspielen. Links heute nicht, rechts merken, unten gesehen, oben Details. Zurück öffnet Navigation und Optionen."
        accessibilityTraits = [.button]
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panFilm(_:)))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        pan.cancelsTouchesInView = true
        addGestureRecognizer(pan)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, inputEnabled { requestFilmFocus() }
    }
    func requestFilmFocus() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.inputEnabled, self.window != nil else { return }
            let system = UIFocusSystem.focusSystem(for: self)
            system?.requestFocusUpdate(to: self)
            system?.updateFocusIfNeeded()
        }
    }
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let selected = context.nextFocusedView === self
        guard selected != lastReportedFocus else { return }
        lastReportedFocus = selected
        DispatchQueue.main.async { [weak self] in self?.focusChanged(selected) }
    }
    override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
        if inputEnabled, isFocused, context.focusHeading != [] { return false }
        return true
    }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard inputEnabled, isFocused else { super.pressesBegan(presses, with: event); return }
        for press in presses {
            switch press.type {
            case .select: action(.play)
            case .menu: action(.navigation)
            case .leftArrow: action(.left)
            case .rightArrow: action(.right)
            case .upArrow: action(.up)
            case .downArrow: action(.down)
            default: super.pressesBegan([press], with: event)
            }
        }
    }
    override func accessibilityActivate() -> Bool { action(.play); return true }
    @objc private func panFilm(_ pan: UIPanGestureRecognizer) {
        guard inputEnabled, isFocused else { return }
        let position = pan.translation(in: self)
        switch pan.state {
        case .began, .changed: preview(CGSize(width: position.x, height: position.y))
        case .ended:
            preview(.zero)
            if let direction = TVFilmPanPolicy.action(x: position.x, y: position.y) { action(direction) }
        case .cancelled, .failed: preview(.zero)
        default: break
        }
    }
}
