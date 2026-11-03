import SwiftUI

/// Titelseite im Guide: alles zum Film und vor allem, wo man ihn findet.
struct GuideDetailView: View {
    @Environment(GuideStore.self) private var store
    @State private var showServices = false
    let film: Film

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
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
        .navigationTitle(film.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: film.shareURL, subject: Text(film.title), message: Text("\(film.title) (\(film.yearText))"))
            }
        }
        .sheet(isPresented: $showServices) { GuideServicesSheet() }
    }

    // MARK: Kopf

    private var header: some View {
        HStack(alignment: .bottom, spacing: 16) {
            PosterView(film: film, cornerRadius: 14)
                .frame(width: 128)
                .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
            VStack(alignment: .leading, spacing: 8) {
                Text(film.title)
                    .font(Theme.filmTitle(size: 28))
                    .fixedSize(horizontal: false, vertical: true)
                if film.originalTitle != film.title {
                    Text(film.originalTitle).font(.subheadline).foregroundStyle(.secondary)
                }
                Text(film.metaLine.replacingOccurrences(of: " · FSK \(film.fsk)", with: ""))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    FSKBadge(fsk: film.fsk)
                    if film.isSeries { TagChip(text: "Serie") }
                    if film.comingSoon { TagChip(text: film.releaseNote ?? "Demnächst") }
                }
                ScoreBadges(film: film, compact: true)
            }
        }
    }

    // MARK: Merken, gesehen

    private var actions: some View {
        HStack(spacing: 10) {
            Button { store.toggleSaved(film) } label: {
                Label(store.isSaved(film) ? "Gemerkt" : "Merken", systemImage: store.isSaved(film) ? "bookmark.fill" : "bookmark")
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(Color.black)
            }
            .buttonStyle(.glassProminent)
            .accessibilityIdentifier("guide.save")

            Button { store.toggleSeen(film) } label: {
                Label(store.isSeen(film) ? "Gesehen" : "Schon gesehen?", systemImage: store.isSeen(film) ? "checkmark.circle.fill" : "eye")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .accessibilityIdentifier("guide.seen")
        }
        .controlSize(.large)
        .sensoryFeedback(.selection, trigger: store.isSaved(film))
    }

    // MARK: Wo schauen

    private var whereToWatch: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Wo läuft \(film.isSeries ? "die Serie" : "der Film")?")
            Text(film.comingSoon
                 ? "Noch nicht erschienen. Die Suche zeigt, wo er angekündigt ist."
                 : "Die Verfügbarkeit wechselt ständig, darum wird sie live gesucht.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let google = WatchLinks.google(film) {
                Link(destination: google) {
                    linkRow(symbol: "magnifyingglass", title: "Bei Google suchen",
                            subtitle: "Zeigt alle Anbieter mit Abo, Leihen und Kaufen", prominent: true)
                }
                .accessibilityIdentifier("guide.link.google")
            }
            if let justWatch = WatchLinks.justWatch(film) {
                Link(destination: justWatch) {
                    linkRow(symbol: "list.bullet.rectangle", title: "Bei JustWatch ansehen",
                            subtitle: "Alle Streamingdienste in Deutschland mit Preisen", prominent: false)
                }
                .accessibilityIdentifier("guide.link.justwatch")
            }

            HStack {
                Text(store.services.isEmpty ? "Direkt beim Dienst suchen" : "Deine Dienste zuerst")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button(store.services.isEmpty ? "Dienste wählen" : "Ändern") { showServices = true }
                    .font(.subheadline)
            }
            .padding(.top, 6)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(store.orderedProviders) { provider in
                    if let url = provider.url(for: film) {
                        Link(destination: url) { providerTile(provider) }
                            .accessibilityIdentifier("guide.provider.\(provider.rawValue)")
                    }
                }
            }
        }
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
        .foregroundStyle(.white)
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

    private var about: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Worum geht's?")
            Text(film.synopsis.withoutDashes)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            WrapLayout(spacing: 8) {
                ForEach(film.genres, id: \.self) { TagChip(text: $0) }
                ForEach(film.moods, id: \.self) { TagChip(text: $0.moodLabel, tint: .secondary) }
            }
            if film.isSeries, let seasons = film.seasons, !seasons.isEmpty {
                Text("\(film.seasonsText), \(seasons.reduce(0) { $0 + $1.episodes.count }) Folgen à etwa \(film.runtime) Min.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var people: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Regie und Besetzung")
            VStack(spacing: 0) {
                if !film.director.isEmpty { personRow(film.director, role: "Regie") }
                ForEach(film.cast, id: \.self) { personRow($0, role: "Besetzung") }
            }
            .background(Color.white.opacity(0.07), in: .rect(cornerRadius: 16))
        }
    }

    private func personRow(_ name: String, role: String) -> some View {
        let count = GuideCatalog.films(with: name).count
        return NavigationLink(value: GuidePerson(name: name)) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.body.weight(.medium))
                    Text(role).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if count > 1 {
                    Text("\(count) Titel").font(.caption).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var moreInfo: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Mehr dazu")
            ScoreLinks(film: film)
            WrapLayout(spacing: 8) {
                if let url = WatchLinks.trailer(film) { infoLink("Trailer auf YouTube", symbol: "play.rectangle", url: url) }
                if let url = WatchLinks.wikipedia(film) { infoLink("Wikipedia", symbol: "book", url: url) }
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
            .foregroundStyle(.white)
            .padding(.horizontal, 12).frame(height: 36)
        }
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    @ViewBuilder private var similar: some View {
        let films = GuideCatalog.similar(to: film)
        if !films.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Das könnte auch passen")
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

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.title3.weight(.bold))
    }
}
