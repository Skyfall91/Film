import SwiftUI

/// Titelseite im Guide: alles zum Film und vor allem, wo man ihn findet.
/// Mit TMDB steht oben, bei welchem Dienst er gerade läuft; sonst führen Suchlinks dorthin.
struct GuideDetailView: View {
    @Environment(GuideStore.self) private var store
    @State private var showServices = false
    @State private var details: FilmDetails?
    @State private var loadingDetails = true
    @State private var showAllServices = false
    let film: Film

    /// Ausführliche Fassung, sobald sie geladen ist.
    private var shown: Film { details?.film ?? film }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                actions
                whereToWatch
                about
                people
                moreInfo
                similar
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background { PosterTintBackground(film: film) }
        .navigationTitle(shown.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: WatchLinks.share(shown), subject: Text(shown.title), message: Text(shareText))
            }
        }
        .sheet(isPresented: $showServices) { GuideServicesSheet() }
        .task(id: "\(film.id)|\(store.tmdbKey)") {
            loadingDetails = true
            let loaded = await OnlineCatalog.details(for: film)
            withAnimation(.smooth) {
                details = loaded
                loadingDetails = false
            }
        }
    }

    private var shareText: String {
        shown.year > 0 ? "\(shown.title) (\(shown.yearText))" : shown.title
    }

    // MARK: Kopf

    private var header: some View {
        HStack(alignment: .bottom, spacing: 16) {
            PosterView(film: film, cornerRadius: 14)
                .frame(width: 132)
                .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
            VStack(alignment: .leading, spacing: 8) {
                Text(shown.title)
                    .font(Theme.filmTitle(size: 28))
                    .fixedSize(horizontal: false, vertical: true)
                if shown.originalTitle != shown.title {
                    Text(shown.originalTitle).font(.subheadline).foregroundStyle(.secondary)
                }
                if !shown.guideMeta.isEmpty {
                    Text(shown.guideMeta).font(.subheadline).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    if shown.fsk >= 0 { FSKBadge(fsk: shown.fsk) }
                    if shown.comingSoon { TagChip(text: shown.releaseNote ?? "Demnächst") }
                }
                if shown.isCurated {
                    ScoreBadges(film: shown, compact: true)
                } else if let rating = shown.tmdbRating {
                    Label { Text("\(rating, format: .number.precision(.fractionLength(1))) bei TMDB") } icon: { Image(systemName: "star.fill") }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Merken, mögen, gesehen

    private var actions: some View {
        HStack(spacing: 10) {
            Button { store.toggleSaved(shown) } label: {
                Label(store.isSaved(film) ? "Gemerkt" : "Merken", systemImage: store.isSaved(film) ? "bookmark.fill" : "bookmark")
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(Color.black)
            }
            .buttonStyle(.glassProminent)
            .accessibilityIdentifier("guide.save")

            Button { store.toggleLiked(shown) } label: {
                Image(systemName: store.isLiked(film) ? "heart.fill" : "heart")
                    .foregroundStyle(store.isLiked(film) ? Color(red: 1.0, green: 0.4, blue: 0.55) : Color.white)
                    .frame(width: 28)
                    .symbolEffect(.bounce, value: store.isLiked(film))
            }
            .buttonStyle(.glass)
            .accessibilityLabel(store.isLiked(film) ? "Mag ich nicht mehr" : "Mag ich")
            .accessibilityIdentifier("guide.like")

            Button { store.toggleSeen(shown) } label: {
                Image(systemName: store.isSeen(film) ? "checkmark.circle.fill" : "eye")
                    .frame(width: 28)
            }
            .buttonStyle(.glass)
            .accessibilityLabel(store.isSeen(film) ? "Nicht gesehen" : "Schon gesehen")
            .accessibilityIdentifier("guide.seen")
        }
        .controlSize(.large)
        .sensoryFeedback(.selection, trigger: store.isSaved(film))
        .sensoryFeedback(.success, trigger: store.isLiked(film))
    }

    // MARK: Wo schauen

    private var whereToWatch: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Wo läuft \(shown.isSeries ? "die Serie" : "der Film")?").font(.title3.weight(.bold))

            if let availability = details?.availability {
                if availability.isEmpty {
                    Text(shown.comingSoon
                         ? "Noch nicht erschienen und noch bei keinem Dienst angekündigt."
                         : "Gerade bei keinem Streamingdienst in Deutschland. Die Suche zeigt, ob es ihn anders gibt.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    offers("Im Abo", availability.flatrate)
                    offers("Kostenlos", availability.free)
                    offers("Leihen", availability.rent)
                    offers("Kaufen", availability.buy)
                    if let link = availability.link, let url = URL(string: link) {
                        Link(destination: url) {
                            Label("Alle Angebote mit Preisen", systemImage: "arrow.up.right")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    Text("Verfügbarkeit: JustWatch über TMDB")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else if loadingDetails && OnlineCatalog.usesTMDB {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Suche Anbieter …").font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                Text(shown.comingSoon
                     ? "Noch nicht erschienen. Die Suche zeigt, wo er angekündigt ist."
                     : "Die Verfügbarkeit wechselt ständig, darum wird sie live gesucht.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let google = WatchLinks.google(shown) {
                Link(destination: google) {
                    linkRow(symbol: "magnifyingglass", title: "Bei Google suchen",
                            subtitle: "Alle Anbieter mit Abo, Leihen und Kaufen", prominent: details?.availability == nil)
                }
                .accessibilityIdentifier("guide.link.google")
            }
            if let justWatch = WatchLinks.justWatch(shown) {
                Link(destination: justWatch) {
                    linkRow(symbol: "list.bullet.rectangle", title: "Bei JustWatch ansehen",
                            subtitle: "Alle Streamingdienste in Deutschland mit Preisen", prominent: false)
                }
                .accessibilityIdentifier("guide.link.justwatch")
            }

            HStack {
                Text(store.services.isEmpty ? "Direkt beim Dienst suchen" : "Bei deinen Diensten suchen")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button(store.services.isEmpty ? "Dienste wählen" : "Ändern") { showServices = true }
                    .font(.subheadline)
            }
            .padding(.top, 4)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(visibleProviders) { provider in
                    if let url = provider.url(for: shown) {
                        Link(destination: url) { providerTile(provider) }
                            .accessibilityIdentifier("guide.provider.\(provider.rawValue)")
                    }
                }
            }
            if !store.services.isEmpty && !showAllServices {
                Button("Alle Dienste zeigen") { withAnimation(.smooth) { showAllServices = true } }
                    .font(.subheadline)
            }
        }
    }

    /// Mit eigenen Diensten nur diese, bis man alle aufklappt.
    private var visibleProviders: [WatchProvider] {
        store.services.isEmpty || showAllServices ? store.orderedProviders : store.orderedProviders.filter { store.services.contains($0) }
    }

    @ViewBuilder private func offers(_ title: String, _ list: [ProviderOffer]) -> some View {
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(list) { offer in
                            if let url = offer.provider?.url(for: shown) ?? details?.availability?.link.flatMap({ URL(string: $0) }) {
                                Link(destination: url) { offerTile(offer) }
                            } else {
                                offerTile(offer)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .scrollClipDisabled()
                .padding(.horizontal, -20)
            }
        }
    }

    private func offerTile(_ offer: ProviderOffer) -> some View {
        let mine = offer.provider.map { store.services.contains($0) } ?? false
        return VStack(spacing: 6) {
            AsyncImage(url: offer.logoURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.white.opacity(0.1)
                    .overlay(Text(String(offer.name.prefix(1))).font(.headline))
            }
            .frame(width: 56, height: 56)
            .clipShape(.rect(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14).stroke(Color.white, lineWidth: mine ? 2 : 0)
            }
            Text(offer.name)
                .font(.caption2)
                .foregroundStyle(mine ? Color.white : Color.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 72)
        }
        .accessibilityElement(children: .combine)
    }

    private func providerTile(_ provider: WatchProvider) -> some View {
        let mine = store.services.contains(provider)
        return HStack(spacing: 10) {
            GuideProviderMark(provider: provider, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(provider.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(provider.kindNote).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
        }
        .foregroundStyle(Color.white)
        .padding(10)
        .background(Color.white.opacity(mine ? 0.16 : 0.07), in: .rect(cornerRadius: 14))
        .overlay {
            if mine { RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.35), lineWidth: 1) }
        }
        .contentShape(.rect)
    }

    private func linkRow(symbol: String, title: String, subtitle: String, prominent: Bool) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).opacity(0.75)
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right").font(.footnote.weight(.bold))
        }
        .foregroundStyle(prominent ? Color.black : Color.white)
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(prominent ? Color.white : Color.white.opacity(0.1), in: .rect(cornerRadius: 18))
        .contentShape(.rect)
    }

    // MARK: Inhalt

    @ViewBuilder private var about: some View {
        let hasText = !shown.synopsis.isEmpty
        if hasText || !shown.genres.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Worum geht's?").font(.title3.weight(.bold))
                if hasText {
                    Text(shown.synopsis.withoutDashes)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                WrapLayout(spacing: 8) {
                    ForEach(shown.genres, id: \.self) { TagChip(text: $0) }
                    ForEach(shown.moods, id: \.self) { TagChip(text: $0.moodLabel, tint: .secondary) }
                }
                if shown.isSeries, let seasons = shown.seasons, !seasons.isEmpty {
                    Text("\(shown.seasonsText), \(seasons.reduce(0) { $0 + $1.episodes.count }) Folgen à etwa \(shown.runtime) Min.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var people: some View {
        if !shown.director.isEmpty || !shown.cast.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(shown.isSeries ? "Macher und Besetzung" : "Regie und Besetzung").font(.title3.weight(.bold))
                VStack(spacing: 0) {
                    if !shown.director.isEmpty { personRow(shown.director, role: shown.isSeries && !shown.isCurated ? "Idee" : "Regie") }
                    ForEach(shown.cast, id: \.self) { personRow($0, role: "Besetzung") }
                }
                .background(Color.white.opacity(0.07), in: .rect(cornerRadius: 16))
            }
        }
    }

    @ViewBuilder private func personRow(_ name: String, role: String) -> some View {
        let count = GuideCatalog.films(with: name).count
        let row = HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body.weight(.medium))
                Text(role).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if count > 0 {
                Text(count == 1 ? "1 Titel" : "\(count) Titel").font(.caption).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
            } else {
                Image(systemName: "arrow.up.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .contentShape(.rect)

        if count > 0 {
            NavigationLink(value: GuidePerson(name: name)) { row }
                .buttonStyle(.plain)
        } else if let url = WatchLinks.person(name) {
            Link(destination: url) { row }
                .foregroundStyle(Color.white)
        }
    }

    private var moreInfo: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mehr dazu").font(.title3.weight(.bold))
            if !shown.imdbID.isEmpty {
                ScoreLinks(film: shown)
            }
            WrapLayout(spacing: 8) {
                if let url = WatchLinks.trailer(shown) { infoLink("Trailer auf YouTube", symbol: "play.rectangle", url: url) }
                if let link = shown.link, let url = URL(string: link) {
                    infoLink(link.contains("apple.com") ? "Bei Apple TV" : "Bei TMDB", symbol: "info.circle", url: url)
                }
                if let url = WatchLinks.wikipedia(shown) { infoLink("Wikipedia", symbol: "book", url: url) }
            }
        }
    }

    private func infoLink(_ title: String, symbol: String, url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(title)
                Image(systemName: "arrow.up.right").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 12).frame(height: 36)
        }
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    @ViewBuilder private var similar: some View {
        let films = GuideCatalog.similar(to: shown)
        if !films.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Das könnte auch passen").font(.title3.weight(.bold))
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(films) { GuideTile(film: $0, width: 110) }
                    }
                    .padding(.horizontal, 20)
                }
                .scrollClipDisabled()
                .padding(.horizontal, -20)
            }
        }
    }
}
