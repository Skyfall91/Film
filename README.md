# Film-Guide

Branch `guide`: Die App ist hier kein Player, sondern ein Guide zum Filmefinden. Sie kennt wirklich alle Filme und zeigt zu jedem, wo er läuft.

- **Kennenlernen**: Posterwand, Lieblingsgenres, ein paar Lieblingsfilme antippen, eigene Streamingdienste
- **Für dich**: große Karten „Heute für dich“ (wechseln täglich), „Worauf hast du Lust?“, „Weil du X magst“, „Gerade beliebt“, Reihen nach Genres
- **Stöbern**: alle Filme und Serien mit Filtern (Art, Genre, Jahrzehnt, Länge, FSK, „Auf meinen Diensten“), endlos scrollbar, oder nur die handverlesenen Titel mit Stimmungen
- **Suche**: erst im Guide, dann in allen Filmen und Serien, mit Personenseiten
- **Titelseite**: wo der Titel gerade im Abo, kostenlos, zum Leihen oder Kaufen läuft, dazu Such-Links zu Google, JustWatch und den Diensten
- **Merkliste**, **Mag ich** (verbessert die Vorschläge) und **Gesehen**, alles auf dem Gerät

### Alle Filme

Mitgeliefert sind gut 400 handverlesene Titel mit Stimmungen und Wertungen, die auch offline gehen. Alles Weitere kommt live dazu:

- **Mit TMDB-Schlüssel** (kostenlos unter [themoviedb.org/settings/api](https://www.themoviedb.org/settings/api)): über eine Million Filme und Serien und die echte Verfügbarkeit in Deutschland (JustWatch-Daten). Den Schlüssel in der App unter *Einstellungen* eintragen, oder als Build-Einstellung `TMDB_API_KEY` in `project.yml`.
- **Ohne Schlüssel**: Apples iTunes-Katalog. Die Suche findet jeden Film, den es in Deutschland zu leihen oder kaufen gibt, Stöbern zeigt die iTunes-Bestenlisten.

Nicht mehr Teil der iPhone-App: Konto, Abo, Profile, Wisch-Empfehlungen, Redaktionstexte und Abspielen. Der Code dafür liegt noch im Projekt (die Apple-TV-App nutzt ihn weiter). Trailer öffnen sich auf YouTube.

## Bauen

```bash
xcodegen generate
open Film.xcodeproj
```

Xcode 26, iOS 26 und tvOS 26. Das Team unter *Signing & Capabilities* einmal auswählen, dann ▶.

## Aufbau

- `App/Guide/`: der Film-Guide (Kennenlernen, Startseite, Stöbern, Suche, Titelseite, Online-Katalog, Links)
- `App/`: iPhone- und iPad-App (SwiftUI)
- `TV/`: Apple-TV-App
- `Packages/FilmSync`: Abgleich zwischen Geräten
- `Packages/LightCode`: Anmeldung am Apple TV per Lichtcode
- `supabase/`: Konten, Geräte und Abos
- `Tests/`: Zustands- und Oberflächentests

Poster werden beim ersten Start geladen und nicht mitgeliefert.

## Daten und Lizenzen

- Weitere Titel und Verfügbarkeit: [TMDB](https://www.themoviedb.org) und JustWatch. Dieses Produkt nutzt die TMDB-API, ist aber nicht von TMDB unterstützt oder zertifiziert.
- Ohne Schlüssel: [iTunes Search API](https://performance-partners.apple.com/search-api)

- Wertungen, Staffeln und Poster-Links: [OMDb API](https://www.omdbapi.com), CC BY-NC 4.0
- Empfehlungsmodell: [MovieLens](https://grouplens.org/datasets/movielens/), GroupLens Research. F. M. Harper, J. A. Konstan: *The MovieLens Datasets: History and Context*. ACM TiiS 5(4), 2015, [doi:10.1145/2827872](https://doi.org/10.1145/2827872). Mitgeliefert werden nur daraus abgeleitete Werte.
- Trailer von den offiziellen Studio-Kanälen auf YouTube, abgespielt mit [YouTubeKit](https://github.com/alexeichhorn/YouTubeKit) (MIT)

Nicht kommerzielles Studienprojekt. Filmtitel, Poster und Trailer gehören ihren Rechteinhabern.
