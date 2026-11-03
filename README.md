# Film-Guide

Branch `guide`: Die App ist hier kein Player mehr, sondern ein Guide zum Filmefinden. Alle Filme und Serien aus dem Katalog lassen sich durchstöbern, filtern, durchsuchen und merken. Auf jeder Titelseite steht, wo man ihn findet: Die Links funktionieren wie bei einer Suchmaschine und öffnen die Live-Suche bei Google (mit der „Ansehen“-Box aller Anbieter), JustWatch und direkt bei den Streamingdiensten.

- **Entdecken**: Am besten bewertet, Neu, Serien, Demnächst, Genres, Stimmungen, Familie, Geheimtipps
- **Alle Titel**: Filter nach Art, Genre, Stimmung, Jahrzehnt, Länge, FSK, Gesehenes ausblenden, Sortierung
- **Suche**: Titel, Originaltitel, Regie, Besetzung, Genre, Stimmung, Jahr, mit Personenseiten
- **Merkliste** und **Gesehen**, auf dem Gerät gespeichert
- **Meine Dienste**: eigene Streamingdienste stehen auf jeder Titelseite oben

Nicht mehr Teil der iPhone-App: Konto, Abo, Onboarding, Profile, Empfehlungs-Swipen, Redaktionstexte und Abspielen. Der Code dafür liegt noch im Projekt (die Apple-TV-App nutzt ihn weiter), wird von der iPhone-App aber nicht mehr gestartet. Trailer öffnen sich auf YouTube.

## Bauen

```bash
xcodegen generate
open Film.xcodeproj
```

Xcode 26, iOS 26 und tvOS 26. Das Team unter *Signing & Capabilities* einmal auswählen, dann ▶.

## Aufbau

- `App/Guide/`: der Film-Guide (Start, Katalog, Suche, Titelseite, Links)
- `App/`: iPhone- und iPad-App (SwiftUI)
- `TV/`: Apple-TV-App
- `Packages/FilmSync`: Abgleich zwischen Geräten
- `Packages/LightCode`: Anmeldung am Apple TV per Lichtcode
- `supabase/`: Konten, Geräte und Abos
- `Tests/`: Zustands- und Oberflächentests

Poster werden beim ersten Start geladen und nicht mitgeliefert.

## Daten und Lizenzen

- Wertungen, Staffeln und Poster-Links: [OMDb API](https://www.omdbapi.com), CC BY-NC 4.0
- Empfehlungsmodell: [MovieLens](https://grouplens.org/datasets/movielens/), GroupLens Research. F. M. Harper, J. A. Konstan: *The MovieLens Datasets: History and Context*. ACM TiiS 5(4), 2015, [doi:10.1145/2827872](https://doi.org/10.1145/2827872). Mitgeliefert werden nur daraus abgeleitete Werte.
- Trailer von den offiziellen Studio-Kanälen auf YouTube, abgespielt mit [YouTubeKit](https://github.com/alexeichhorn/YouTubeKit) (MIT)

Nicht kommerzielles Studienprojekt. Filmtitel, Poster und Trailer gehören ihren Rechteinhabern.
