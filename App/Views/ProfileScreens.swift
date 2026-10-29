import SwiftUI

// MARK: - Avatare

// MARK: - Profil erstellen

/// Profil anlegen wie bei den großen Streamingdiensten: großes Profilbild im Mittelpunkt,
/// Name darunter, Kinderprofil als eigene Karte.
struct ProfileEditor: View {
    var isFirst: Bool
    /// Vorhandenes Profil bearbeiten statt ein neues anlegen.
    var editing: Profile? = nil
    /// Abbrechen-Knopf oben links (nur, wo man auch zurück kann).
    var cancel: (() -> Void)? = nil
    /// Löschen-Knopf unten (nur beim Bearbeiten).
    var delete: (() -> Void)? = nil
    /// Profil wird gerade erst angelegt (Zurück aus der Filmauswahl): „Weiter“ statt „Sichern“.
    var continuing = false
    var next: (_ name: String, _ avatar: AvatarArt, _ maxFSK: Int, _ littleKid: Bool) -> Void

    @State private var name = ""
    @State private var art = AvatarArt.all.randomElement()!
    @State private var kid = false
    @State private var fsk = 6
    @State private var little = false
    @State private var picking = false
    @State private var confirmDelete = false
    @FocusState private var focused: Bool

    init(isFirst: Bool, editing: Profile? = nil, continuing: Bool = false, cancel: (() -> Void)? = nil, delete: (() -> Void)? = nil,
         next: @escaping (_ name: String, _ avatar: AvatarArt, _ maxFSK: Int, _ littleKid: Bool) -> Void) {
        self.isFirst = isFirst; self.editing = editing; self.continuing = continuing
        self.cancel = cancel; self.delete = delete; self.next = next
        if let p = editing {
            _name = State(initialValue: p.name)
            _art = State(initialValue: p.avatarArt ?? AvatarArt.all[p.colorIndex % AvatarArt.all.count])
            _kid = State(initialValue: p.maxFSK < 18)
            _fsk = State(initialValue: p.maxFSK < 18 ? p.maxFSK : 6)
            _little = State(initialValue: p.littleKid)
        }
    }

    /// Feste Reihe zum Durchtippen: Sie sortiert sich beim Antippen nicht um,
    /// sonst verschwindet die Figur, die gerade noch vorne stand.
    @State private var quickPicks: [AvatarArt] = []

    private static func makeQuickPicks(including art: AvatarArt) -> [AvatarArt] {
        let picks = (0..<2).flatMap { i in AvatarArt.categories.compactMap { AvatarArt.byID("\($0.key)-\(i)") } }
        return picks.contains(art) ? picks : [art] + picks
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 26) {
                    VStack(spacing: 6) {
                        Text(editing != nil && !continuing ? "Profil bearbeiten" : isFirst ? "Dein Profil" : "Neues Profil")
                            .font(.largeTitle.weight(.heavy))
                        Text("Jedes Profil lernt seinen eigenen Geschmack.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.top, 28)

                    Button { picking = true } label: {
                        AvatarTile(art: art, size: 168)
                            .id(art.id)
                            .transition(.asymmetric(insertion: .scale(scale: 0.85).combined(with: .opacity),
                                                    removal: .opacity))
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "pencil")
                                    .font(.headline)
                                    .frame(width: 44, height: 44)
                                    .glassEffect(.regular.interactive(), in: .circle)
                                    .offset(x: 10, y: 10)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Profilbild ändern")

                    quickStrip

                    TextField("", text: $name, prompt: Text("Name").foregroundStyle(.white.opacity(0.35)))
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit { focused = false }
                        .padding(.vertical, 16)
                        .glassEffect(in: .capsule)
                        .padding(.horizontal, 24)

                    kidCard.padding(.horizontal, 20)

                    if let delete {
                        Button("Profil löschen", systemImage: "trash", role: .destructive) { confirmDelete = true }
                            .font(.headline)
                            .confirmationDialog("„\(editing?.name ?? name)“ löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
                                Button("Profil löschen", role: .destructive, action: delete)
                            } message: {
                                Text("Merkliste, Bewertungen und der gelernte Geschmack dieses Profils gehen verloren.")
                            }
                    }
                }
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .toolbar {
            if let cancel {
                ToolbarItem(placement: .cancellationAction) { Button(role: .close, action: cancel).tint(.white) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button(action: submit) {
                Text(editing != nil && !continuing ? "Sichern" : "Weiter").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .foregroundStyle(.black)
            .controlSize(.large)
            .disabled(trimmed.isEmpty)
            .padding(.horizontal, 24).padding(.bottom, 8)
        }
        .sheet(isPresented: $picking) {
            AvatarPicker(selection: $art)
        }
        .onAppear { if quickPicks.isEmpty { quickPicks = Self.makeQuickPicks(including: art) } }
        .onChange(of: art) { _, new in
            // Aus der großen Auswahl: vorne einreihen, ohne eine andere Figur zu verdrängen.
            if !quickPicks.contains(new) { withAnimation(.snappy) { quickPicks.insert(new, at: 0) } }
        }
        .sensoryFeedback(.selection, trigger: art)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    private var quickStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(quickPicks.isEmpty ? Self.makeQuickPicks(including: art) : quickPicks) { a in
                    Button { withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { art = a } } label: {
                        AvatarTile(art: a, size: 56)
                            .overlay(RoundedRectangle(cornerRadius: 56 * 0.24 + 5, style: .continuous)
                                .strokeBorder(.white, lineWidth: 2.5).padding(-5).opacity(a == art ? 1 : 0))
                            .scaleEffect(a == art ? 1 : 0.9)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Profilbild \(a.emoji)")
                }
                Button { picking = true } label: {
                    Image(systemName: "square.grid.2x2")
                        .font(.title3)
                        .frame(width: 56, height: 56)
                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 56 * 0.24))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Alle Profilbilder")
            }
            .padding(.horizontal, 24).padding(.vertical, 6)
        }
    }

    private var kidCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: $kid.animation(.smooth)) {
                HStack(spacing: 12) {
                    Image(systemName: "figure.and.child.holdinghands")
                        .font(.title3).foregroundStyle(.secondary)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Kinderprofil").font(.headline)
                        Text("Nur altersgerechte Filme und Serien").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .tint(.green)
            if kid {
                // „Bis 5“ ist FSK 0 plus nur Kinder- und Familientitel.
                HStack(spacing: 8) {
                    ForEach([(-1, "Bis 5 J."), (6, "FSK 6"), (12, "FSK 12"), (16, "FSK 16")], id: \.0) { value, label in
                        let on = value == -1 ? little : (!little && fsk == value)
                        Button {
                            withAnimation(.snappy) {
                                little = value == -1
                                fsk = max(value, 0)
                            }
                        } label: {
                            Text(label)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1).minimumScaleFactor(0.8)
                                .frame(maxWidth: .infinity, minHeight: 38)
                                .foregroundStyle(on ? .black : .white)
                                .background(on ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.08)), in: .capsule)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text(little
                     ? "Nur Zeichentrick- und Familientitel ohne Altersgrenze. Statt zu wischen, suchst du gleich die Lieblingsfilme deines Kindes aus."
                     : "Vorschläge, Suche und Katalog zeigen nur Titel bis FSK \(fsk), auch wenn das Profil mit anderen zusammen schaut.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .glassEffect(in: .rect(cornerRadius: 26))
    }

    private func submit() {
        guard !trimmed.isEmpty else { return }
        // Erst die Tastatur wegnehmen, dann weiter, sonst springt der nächste Schritt.
        focused = false
        Task {
            try? await Task.sleep(for: .milliseconds(320))
            next(trimmed, art, kid ? fsk : 18, kid && little)
        }
    }
}

// MARK: - Profile verwalten

/// Alle Profile des Haushalts: umbenennen, Bild und Altersstufe ändern, löschen.
/// Hier liegt auch der Import von Letterboxd und IMDb, bewusst nicht im Onboarding.
struct ManageProfilesView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    @State private var editing: UUID?
    @State private var adding = false
    @State private var importing: UUID?
    @State private var confirmDelete: Profile?

    /// Importieren ergibt nur bei Erwachsenen Sinn, Kinder haben kein Letterboxd.
    private var importable: [Profile] { store.profiles.filter { !$0.isKid } }

    var body: some View {
        ScrollView {
            VStack(spacing: 30) {
                Text("Welches Profil möchtest du bearbeiten?")
                    .font(.title2.weight(.bold)).multilineTextAlignment(.center)
                    .padding(.top, 24)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 150), spacing: 28)], spacing: 30) {
                    ForEach(store.profiles) { profile in
                        Button { editing = profile.id } label: {
                            VStack(spacing: 12) {
                                AvatarTile(art: profile.avatarArt, initial: profile.initial, color: profile.color, size: 120)
                                    .overlay(alignment: .bottomTrailing) {
                                        Image(systemName: "pencil")
                                            .font(.system(size: 17, weight: .semibold))
                                            .foregroundStyle(.black)
                                            .frame(width: 34, height: 34)
                                            .background(.white, in: .circle)
                                            .overlay(Circle().stroke(.black, lineWidth: 3))
                                            .offset(x: 5, y: 5)
                                    }
                                Text(profile.name).font(.headline)
                                Text(profile.ageLabel).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(profile.name) bearbeiten")
                    }
                    if store.canAddProfile {
                        Button { adding = true } label: {
                            VStack(spacing: 12) {
                                Image(systemName: "plus").font(.system(size: 34, weight: .medium))
                                    .frame(width: 120, height: 120)
                                    .background(.white.opacity(0.06), in: .rect(cornerRadius: 29))
                                Text("Profil hinzufügen").font(.subheadline)
                            }.foregroundStyle(.secondary)
                        }.buttonStyle(.plain)
                    }
                }
                Text("Tippe auf ein Profil, um Name, Bild oder Altersfreigabe zu ändern.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if !importable.isEmpty {
                Section {
                    if importable.count == 1, let only = importable.first {
                        Button("Von Letterboxd oder IMDb importieren", systemImage: "square.and.arrow.down") { importing = only.id }
                    } else {
                        Menu {
                            ForEach(importable) { p in Button(p.name) { importing = p.id } }
                        } label: {
                            Label("Von Letterboxd oder IMDb importieren", systemImage: "square.and.arrow.down")
                        }
                    }
                } header: {
                    Text("Bewertungen mitbringen")
                } footer: {
                    Text("Wer schon Filme bewertet hat, kann den Daten-Export (ratings.csv) laden. Die Vorschläge werden dadurch genauer.")
                }
            }
        }
            .frame(maxWidth: 720).frame(maxWidth: .infinity)
            .padding(28)
        }
        .navigationTitle("Profile verwalten")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
        .fullScreenCover(item: Binding(get: { editing.map(IdentifiedUUID.init) }, set: { editing = $0?.id })) { item in
            if let profile = store.profiles.first(where: { $0.id == item.id }) {
                NavigationFrame {
                ProfileEditor(isFirst: false, editing: profile, cancel: { editing = nil },
                              delete: store.canDeleteProfile ? { store.deleteProfile(profile.id); editing = nil } : nil) { name, art, fsk, little in
                    store.editProfile(profile.id, name: name, avatar: art, maxFSK: fsk, littleKid: little)
                    editing = nil
                }
                }
                .preferredColorScheme(.dark)
            }
        }
        .fullScreenCover(isPresented: $adding) {
            OnboardingFlow(mode: .addProfile, cancel: { adding = false }) { _ in adding = false }
        }
        .sheet(item: Binding(get: { importing.map(IdentifiedUUID.init) }, set: { importing = $0?.id })) { item in
            ImportStep(profileID: item.id) { importing = nil }
                .preferredColorScheme(.dark)
        }
        .confirmationDialog("„\(confirmDelete?.name ?? "")“ löschen?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Profil löschen", role: .destructive) {
                if let p = confirmDelete { withAnimation { store.deleteProfile(p.id) } }
                confirmDelete = nil
            }
        } message: {
            Text("Merkliste, Bewertungen und der gelernte Geschmack dieses Profils gehen verloren.")
        }
    }
}

/// Alle Profilbilder, nach Genre in Reihen, die Galerie, aus der man sich „seine Figur“ aussucht.
struct AvatarPicker: View {
    @Binding var selection: AvatarArt
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    ForEach(AvatarArt.categories, id: \.key) { c in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(c.name).font(.title3.weight(.bold)).padding(.horizontal, 20)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 14) {
                                    ForEach(AvatarArt.inCategory(c.name)) { a in
                                        Button {
                                            selection = a
                                            dismiss()
                                        } label: {
                                            AvatarTile(art: a, size: 96)
                                                .overlay(RoundedRectangle(cornerRadius: 96 * 0.24 + 6, style: .continuous)
                                                    .strokeBorder(.white, lineWidth: 3).padding(-6).opacity(a == selection ? 1 : 0))
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("\(c.name): \(a.emoji)")
                                    }
                                }
                                .padding(.horizontal, 20).padding(.vertical, 6)
                            }
                            .scrollClipDisabled()
                        }
                    }
                }
                .padding(.vertical, 12)
            }
            .navigationTitle("Profilbild wählen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen", systemImage: "xmark") { dismiss() } }
            }
        }
        .presentationDetents([.large])
    }
}

// MARK: - Wer schaut?

/// Startbildschirm bei mehreren Profilen. Mehrere antippen = zusammen schauen.
struct WhoIsWatchingView: View {
    @Environment(AppStore.self) private var store
    @State private var selected: [UUID] = []
    @State private var adding = false
    @State private var appeared = false
    /// Angetipptes pausiertes Profil (nach Wechsel in einen kleineren Tarif).
    @State private var paused: Profile?
    @State private var changingPlan = false

    var body: some View {
        let plan = store.subscription?.plan
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 30) {
                    VStack(spacing: 6) {
                        Text("Wer schaut?").font(.largeTitle.weight(.heavy))
                        Text(plan?.allowsTogether == false ? "Wähle dein Profil." : "Mehrere antippen, um zusammen zu schauen.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.top, 48)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 150), spacing: 22)], spacing: 26) {
                        ForEach(Array(store.profiles.enumerated()), id: \.element.id) { i, profile in
                            tile(profile)
                                .opacity(appeared ? 1 : 0)
                                .offset(y: appeared ? 0 : 16)
                                .animation(.smooth(duration: 0.5).delay(Double(i) * 0.06), value: appeared)
                        }
                        if store.canAddProfile {
                            Button { adding = true } label: {
                                VStack(spacing: 10) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 34, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 120, height: 120)
                                        .overlay(RoundedRectangle(cornerRadius: 120 * 0.24, style: .continuous)
                                            .strokeBorder(.white.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
                                    Text("Profil hinzufügen").font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 28)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button { withAnimation(.smooth) { store.chooseViewers(selected) } } label: {
                Text(buttonTitle).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                    .contentTransition(.numericText())
            }
            .buttonStyle(.glassProminent)
            .foregroundStyle(.black)
            .controlSize(.large)
            .disabled(selected.isEmpty)
            .padding(.horizontal, 24).padding(.bottom, 8)
        }
        .fullScreenCover(isPresented: $adding) {
            OnboardingFlow(mode: .addProfile, cancel: { adding = false }) { id in
                selected = [id]
                adding = false
            }
        }
        .onAppear {
            if selected.isEmpty { selected = Array(store.activeProfileIDs.prefix(1)) }
            if selected.isEmpty, let first = store.profiles.first { selected = [first.id] }
            appeared = true
        }
        .sensoryFeedback(.selection, trigger: selected)
        .confirmationDialog(pausedTitle, isPresented: Binding(get: { paused != nil }, set: { if !$0 { paused = nil } }),
                            titleVisibility: .visible, presenting: paused) { profile in
            ForEach(store.profiles.filter { !store.isPaused($0.id) }) { active in
                Button("Statt \(active.name) aktiv schalten") {
                    withAnimation(.smooth) {
                        store.unpause(profile.id, replacing: active.id)
                        selected = selected.map { $0 == active.id ? profile.id : $0 }
                        if selected.isEmpty { selected = [profile.id] }
                    }
                }
            }
            Button("Tarif ändern") { changingPlan = true }
            Button("Abbrechen", role: .cancel) {}
        } message: { _ in
            Text("Alles bleibt gespeichert: Geschmack, Merkliste, Bewertungen.")
        }
        .sheet(isPresented: $changingPlan) { NavigationFrame { PlanPicker(mode: .upgrade) { _ in changingPlan = false } } }
    }

    private var pausedTitle: String {
        let plan = store.subscription?.plan
        let n = plan?.maxProfiles ?? 1
        return "\(paused?.name ?? "Profil") ist pausiert. Im Tarif \(plan?.name ?? "") \(n == 1 ? "ist 1 Profil" : "sind \(n) Profile") aktiv."
    }

    private var buttonTitle: String {
        let names = store.profiles.filter { selected.contains($0.id) }.map(\.name)
        switch names.count {
        case 0: return "Profil wählen"
        case 1: return "Los geht's, \(names[0])"
        default: return "Zusammen schauen (\(names.count))"
        }
    }

    private func tile(_ profile: Profile) -> some View {
        let on = selected.contains(profile.id)
        let isPaused = store.isPaused(profile.id)
        return Button {
            if isPaused { paused = profile; return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                if store.subscription?.plan.allowsTogether == false {
                    selected = [profile.id]
                } else if on {
                    selected.removeAll { $0 == profile.id }
                } else {
                    selected.append(profile.id)
                }
            }
        } label: {
            VStack(spacing: 10) {
                AvatarTile(art: profile.avatarArt, initial: profile.initial, color: profile.color, size: 120)
                    // Rahmen mit gleichem Abstand rundum: Radius = Icon-Radius + Abstand, Linie nach innen.
                    .overlay(RoundedRectangle(cornerRadius: 120 * 0.24 + 7, style: .continuous)
                        .strokeBorder(.white, lineWidth: 3).padding(-7).opacity(on ? 1 : 0))
                    .overlay(alignment: .topTrailing) {
                        if on {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title2).symbolRenderingMode(.palette)
                                .foregroundStyle(.black, .white)
                                .offset(x: 10, y: -10)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        if profile.isKid {
                            Text("Kinder").font(.caption2.weight(.heavy))
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(.black.opacity(0.6), in: .capsule)
                                .padding(8)
                        }
                    }
                    .overlay {
                        if isPaused {
                            Image(systemName: "lock.fill")
                                .font(.title.weight(.semibold))
                                .frame(width: 120, height: 120)
                                .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 120 * 0.24, style: .continuous))
                        }
                    }
                    .scaleEffect(on ? 1.04 : 1)
                    .saturation(isPaused ? 0 : (on || selected.isEmpty ? 1 : 0.55))
                    .opacity(on || selected.isEmpty ? 1 : 0.7)
                VStack(spacing: 2) {
                    Text(profile.name)
                        .font(.headline)
                        .foregroundStyle(on ? .primary : .secondary)
                    if isPaused { Text("Pausiert").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPaused ? "\(profile.name), pausiert" : profile.name)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
