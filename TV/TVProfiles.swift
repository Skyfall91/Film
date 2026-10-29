import SwiftUI

struct TVViewerPicker: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var required = false
    @State private var selected: [UUID] = []
    @State private var create = false
    @State private var plans = false
    private var together: Bool { store.subscription?.plan.allowsTogether ?? true }

    var body: some View {
        TVScreen(title: "Wer schaut mit?", subtitle: together ? "Wähle ein Profil oder mehrere für einen gemeinsamen Vorschlag." : "Dein Solo-Tarif erlaubt ein aktives Profil. Gemeinsam schauen gibt es ab Duo.") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 225), spacing: 36)], spacing: 36) {
                ForEach(store.profiles) { profile in
                    Button {
                        if selected.contains(profile.id) { selected.removeAll { $0 == profile.id } }
                        else if together { selected.append(profile.id) }
                        else { selected = [profile.id] }
                    } label: {
                        VStack(spacing: 18) {
                            TVAvatarView(profile: profile, size: 135)
                            Text(profile.name).font(.system(size: 26))
                            Text(store.isPaused(profile.id) ? "Pausiert" : profile.ageLabel).font(.caption).foregroundStyle(.secondary)
                            Image(systemName: selected.contains(profile.id) ? "checkmark.circle.fill" : "circle").font(.system(size: 32, weight: .semibold))
                        }.frame(width: 240).padding(16)
                    }.buttonStyle(.card).disabled(store.isPaused(profile.id))
                }
            }
            HStack(spacing: 28) {
                Button(selected.count > 1 ? "Gemeinsam starten" : "Starten") {
                    store.chooseViewers(TVViewerSelection.normalized(selected, available: store.profiles.filter { !store.isPaused($0.id) }.map(\.id), allowsTogether: together))
                    if !required { dismiss() }
                }.disabled(selected.isEmpty)
                if store.canAddProfile { Button("Profil erstellen") { create = true } }
                Button("Tarife ansehen") { plans = true }
            }
            if selected.count > 1 {
                Text("Es gilt die strengste Altersgrenze aller ausgewählten Profile. Bewertungen bleiben persönlich.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { selected = TVViewerSelection.normalized(store.activeProfileIDs, available: store.profiles.filter { !store.isPaused($0.id) }.map(\.id), allowsTogether: together) }
        .sheet(isPresented: $create) { TVProfileEditor(isFirst: false) { _ in } }
        .sheet(isPresented: $plans) { TVPlanPicker() }
    }
}

struct TVProfilesView: View {
    @Environment(AppStore.self) private var store
    @State private var viewers = false
    @State private var create = false
    @State private var editing: Profile?
    @State private var taste: Profile?
    @State private var paused: Profile?
    @State private var plans = false

    var body: some View {
        TVScreen(title: "Profil") {
            HStack(spacing: 28) {
                Button("Wer schaut?") { viewers = true }
                NavigationLink { TVAccountView() } label: { Label("Konto & Abo", systemImage: "gearshape") }
                Button("Profil erstellen") { create = true }.disabled(!store.canAddProfile)
                if !store.canAddProfile { Button("Mehr Profile mit anderem Tarif") { plans = true } }
            }
            ForEach(store.profiles) { profile in
                HStack(spacing: 26) {
                    TVAvatarView(profile: profile, size: 85)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(profile.name).font(.system(size: 32, weight: .semibold))
                        Text(profile.ageLabel + (store.isPaused(profile.id) ? " · pausiert" : "")).foregroundStyle(.secondary)
                    }.frame(width: 460, alignment: .leading)
                    Button("Bearbeiten") { editing = profile }
                    Button("Geschmack") { taste = profile }.disabled(store.isPaused(profile.id))
                    if store.isPaused(profile.id) { Button("Aktivieren") { paused = profile } }
                }.padding(.vertical, 12)
            }
            Text("\(store.profiles.count) von \(store.profileLimit) Profilen im aktuellen Tarif. Pausierte Profile behalten ihre Bewertungen und Merklisten.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(isPresented: $viewers) { TVViewerPicker() }
        .sheet(isPresented: $create) { TVProfileEditor(isFirst: false) { _ in } }
        .sheet(item: $editing) { profile in TVProfileEditor(editing: profile, isFirst: false) { _ in } }
        .fullScreenCover(item: $taste) { profile in NavigationStack { TVTasteView(profileID: profile.id) }.presentationSizing(.page) }
        .sheet(isPresented: $plans) { TVPlanPicker() }
        .sheet(item: $paused) { profile in
            TVScreen(title: "\(profile.name) aktivieren", subtitle: "Wähle das Profil, das dafür pausiert werden soll. Seine Daten bleiben erhalten.") {
                ForEach(store.profiles.filter { !store.isPaused($0.id) }) { other in
                    Button("\(other.name) pausieren") { store.unpause(profile.id, replacing: other.id); paused = nil }
                }
                Button("Abbrechen") { paused = nil }
            }
        }
    }
}

struct TVProfileEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var editing: Profile? = nil
    let isFirst: Bool
    var onSaved: (UUID) -> Void
    @State private var name = ""
    @State private var avatar = AvatarArt.all[0]
    @State private var maxFSK = 18
    @State private var littleKid = false
    @State private var category = "Science-Fiction"
    @State private var deleteConfirm = false
    @State private var createdID: UUID?
    @State private var error: String?

    var body: some View {
        if let createdID {
            TVCalibrationView(profileID: createdID) { onSaved(createdID); dismiss() }
        } else {
            TVScreen(title: editing == nil ? "Dein Profil" : "Profil bearbeiten", subtitle: "Name, Figur und Altersgrenze gehören zu diesem Profil.") {
                HStack(alignment: .top, spacing: 75) {
                    VStack(alignment: .leading, spacing: 28) {
                        TextField("Profilname", text: $name).frame(width: 520)
                        Picker("Altersfreigabe", selection: $maxFSK) {
                            ForEach([0,6,12,16,18], id: \.self) { value in
                                Text(value == 18 ? "Erwachsene · FSK 18" : "Bis FSK \(value)").tag(value)
                            }
                        }.frame(width: 520)
                        Toggle("Kleine Kinder bis etwa 5 Jahre", isOn: $littleKid).frame(width: 520)
                            .onChange(of: littleKid) { _, value in if value { maxFSK = 0 } }
                        Text(littleKid ? "Nur Animation und Familie ab FSK 0. Eltern wählen gleich die Lieblingsfilme." : "Die Altersgrenze gilt auch beim gemeinsamen Schauen.")
                            .font(.caption).foregroundStyle(.secondary).frame(width: 520)
                        HStack(spacing: 22) {
                            Button("Speichern") { save() }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            if !isFirst { Button("Abbrechen") { dismiss() } }
                        }
                        if editing != nil {
                            Button("Profil löschen", role: .destructive) { deleteConfirm = true }.disabled(!store.canDeleteProfile)
                            if !store.canDeleteProfile { Text("Das letzte Profil bleibt erhalten.").font(.caption) }
                        }
                        if let error { Text(error).foregroundStyle(.red) }
                    }
                    VStack(alignment: .leading, spacing: 25) {
                        Text("Deine Figur").font(.system(size: 32, weight: .semibold))
                        Picker("Kategorie", selection: $category) {
                            ForEach(AvatarArt.categories.map(\.name), id: \.self) { Text($0).tag($0) }
                        }.frame(width: 600)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 24) {
                            ForEach(AvatarArt.inCategory(category)) { art in
                                Button { avatar = art } label: {
                                    VStack {
                                        AvatarTile(art: art, size: 100)
                                        if art.id == avatar.id { Image(systemName: "checkmark.circle.fill") }
                                    }.frame(width: 94, height: 110).background(art.color.opacity(0.2), in: RoundedRectangle(cornerRadius: 18))
                                }.buttonStyle(.card).accessibilityLabel("\(art.category), Figur \(art.emoji)\(art.id == avatar.id ? ", ausgewählt" : "")")
                            }
                        }.frame(width: 600)
                    }
                }
            }
            .onAppear {
                guard let editing else { return }
                name = editing.name; avatar = editing.avatarArt ?? AvatarArt.all[0]
                category = avatar.category; maxFSK = editing.maxFSK; littleKid = editing.littleKid
            }
            .confirmationDialog("Profil samt Geschmack und Merkliste löschen?", isPresented: $deleteConfirm, titleVisibility: .visible) {
                Button("Profil löschen", role: .destructive) {
                    if let editing, store.canDeleteProfile { store.deleteProfile(editing.id); dismiss() }
                }
                Button("Abbrechen", role: .cancel) {}
            }
        }
    }

    private func save() {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let age = littleKid ? 0 : maxFSK
        if let editing {
            store.editProfile(editing.id, name: value, avatar: avatar, maxFSK: age, littleKid: littleKid)
            onSaved(editing.id); dismiss()
        } else {
            guard store.canAddProfile else { error = "Dein Tarif hat keinen freien Profilplatz. Wähle im Konto einen anderen Tarif."; return }
            let id = store.addProfile(name: value, colorIndex: avatar.colorIndex, maxFSK: age, littleKid: littleKid, avatar: avatar.id)
            if isFirst { onSaved(id) } else { createdID = id }
        }
    }
}

struct TVCalibrationView: View {
    @Environment(AppStore.self) private var store
    let profileID: UUID
    var done: () -> Void
    @State private var picker: CalibrationPicker?
    @State private var current: Film?
    @State private var shown: Set<String> = []
    @State private var rated = 0
    @State private var favorites: Set<String> = []
    @State private var reveal = false
    private var profile: Profile? { store.profiles.first { $0.id == profileID } }

    var body: some View {
        if reveal, let profile {
            TVScreen(title: "Das passt zu \(profile.name)", subtitle: "Dein Geschmack wächst mit jeder Bewertung.") {
                Text(TasteSummary(profile: profile).sentence).font(.system(size: 38)).frame(maxWidth: 1050, alignment: .leading)
                Text("\(profile.signalCount) Geschmackssignale gespeichert.").foregroundStyle(.secondary)
                Button("Fertig") { done() }
            }
        } else if profile?.littleKid == true {
            TVScreen(title: "Welche Filme liebt \(profile?.name ?? "dein Kind")?", subtitle: "Wähle bekannte Lieblingsfilme. Die Auswahl bleibt auf FSK 0, Animation und Familie begrenzt.") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 225), spacing: 30)], spacing: 35) {
                    ForEach(FilmIndex.all.filter { $0.forLittleKids && !$0.comingSoon }) { film in
                        Button {
                            if favorites.contains(film.id) { favorites.remove(film.id) } else { favorites.insert(film.id) }
                        } label: {
                            VStack {
                                TVPosterView(film: film, width: 185, height: 278)
                                Text(film.title).font(.caption).lineLimit(2)
                                Image(systemName: favorites.contains(film.id) ? "checkmark.circle.fill" : "circle")
                            }.frame(width: 210).padding(12)
                        }.buttonStyle(.card)
                    }
                }
                Button("\(favorites.count) Lieblingsfilme übernehmen") {
                    for id in favorites { if let film = FilmIndex.film(id) { store.calibrate(profile: profileID, film: film, .loved) } }
                    reveal = true
                }
            }
        } else {
            TVScreen(title: "Was magst du, \(profile?.name ?? "")?", subtitle: "Bewerte Filme, die du kennst. Ungesehene Titel kannst du überspringen.") {
                if let film = current {
                    HStack(alignment: .top, spacing: 60) {
                        TVPosterView(film: film, width: 270, height: 405)
                        VStack(alignment: .leading, spacing: 26) {
                            Text(film.title).font(.system(size: 44, weight: .bold))
                            Text(film.metaLine).foregroundStyle(.secondary)
                            Text(film.hook).font(.system(size: 26)).frame(maxWidth: 850, alignment: .leading)
                            HStack(spacing: 24) {
                                Button("Mag ich nicht") { rate(.disliked) }
                                Button("Mag ich") { rate(.liked) }
                                Button("Liebe ich") { rate(.loved) }
                            }
                            Button("Nicht gesehen · weiter") { rate(.unseen) }
                            Text("\(rated) Filme bewertet · empfohlen sind mindestens 8").font(.caption).foregroundStyle(.secondary)
                            Button("Geschmack ansehen und abschließen") { reveal = true }
                        }
                    }
                } else {
                    TVEmptyState(title: "Alles durchgesehen", message: "Dein Profil ist bereit. Weitere Titel kannst du später im Katalog bewerten.")
                    Button("Geschmack ansehen") { reveal = true }
                }
            }.onAppear { if picker == nil { picker = CalibrationPicker(profile: profile, excluding: Set(profile?.interactions.keys.map { $0 } ?? [])); next() } }
        }
    }

    private func rate(_ action: Interaction) {
        guard let current else { return }
        store.calibrate(profile: profileID, film: current, action)
        picker?.record(current, seen: action != .unseen)
        if action != .unseen { rated += 1 }
        next()
    }
    private func next() {
        current = picker?.next(1, excluding: shown).first
        if let current { shown.insert(current.id) }
    }
}

struct TVTasteView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    let profileID: UUID
    @State private var training = false
    @State private var companion: TVCompanionRequest?
    private var profile: Profile? { store.profiles.first { $0.id == profileID } }

    var body: some View {
        TVScreen(title: "Dein Filmgeschmack", subtitle: profile?.name) {
            if let profile {
                Text(TasteSummary(profile: profile).sentence).font(.system(size: 36)).frame(maxWidth: 1050, alignment: .leading)
                Text("\(profile.signalCount) Geschmackssignale · \(profile.importedCount) importierte Bewertungen").foregroundStyle(.secondary)
                HStack(spacing: 28) {
                    Button("Weitere Filme bewerten") { training = true }
                    Button("Geschmack auf iPhone beschreiben") { companion = TVCompanionRequest(kind: "taste", title: "Geschmack beschreiben", profileID: profileID) }
                    Button("Bewertungen importieren") { companion = TVCompanionRequest(kind: "import", title: "Letterboxd / IMDb importieren", profileID: profileID) }
                }
                if !profile.reviews.isEmpty {
                    Text("Deine Bewertungen").font(.system(size: 36, weight: .bold))
                    ForEach(profile.reviews, id: \.filmID) { review in
                        if let film = FilmIndex.film(review.filmID), profile.allows(film), TVContentPolicy.isVisible(viewersAllow: store.activeProfiles.map { $0.allows(film) }) {
                            NavigationLink { TVFilmDetailsView(film: film) } label: {
                                HStack {
                                    Text(film.title).frame(width: 460, alignment: .leading)
                                    Text(TVRatingView.label(review.rating))
                                    if !review.text.isEmpty { Text(review.text).lineLimit(2).foregroundStyle(.secondary) }
                                }.padding(14)
                            }
                        }
                    }
                }
            } else { TVEmptyState(title: "Profil wurde gelöscht", message: "Schließe diese Ansicht und wähle ein anderes Profil.", symbol: "person") }
        }
        .onExitCommand { dismiss() }
        .sheet(isPresented: $training) { TVCalibrationView(profileID: profileID) { training = false } }
        .sheet(item: $companion) { request in TVCompanionView(store: store, request: request) }
    }
}
