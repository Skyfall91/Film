# Film

Ein Film statt tausend Kacheln. Film lernt beim Wischen deinen Geschmack und schlägt dir genau einen Titel für heute vor.

<p>
  <img src="Screenshots/app/04-geschmack.png" width="200" alt="Geschmack">
  <img src="Screenshots/app/02-profil-erstellen.png" width="200" alt="Profil">
  <img src="Screenshots/app/06-abo.png" width="200" alt="Abo">
</p>

## Bauen

```bash
xcodegen generate
open Film.xcodeproj
```

Xcode 26, iOS 26 und tvOS 26. Das Team unter *Signing & Capabilities* einmal auswählen, dann ▶.

## Aufbau

- `App/`: iPhone- und iPad-App (SwiftUI)
- `TV/`: Apple-TV-App
- `Packages/FilmSync`: Abgleich zwischen Geräten
- `Packages/LightCode`: Anmeldung am Apple TV per Lichtcode
- `supabase/`: Konten, Geräte und Abos
- `Tests/`: Zustands- und Oberflächentests

Poster werden beim ersten Start geladen und nicht mitgeliefert. „Abspielen“ zeigt den offiziellen Trailer.
