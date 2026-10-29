# Film Lichtcode, Format 1

Ein Einzelbild überträgt den vollständigen öffentlichen sechsstelligen Kopplungscode. Es enthält keine Kontokennung und keinen Zugangstoken. Eine optische Lesung autorisiert nie ein Gerät; die iPhone-App löst den Code beim Server auf und verlangt eine ausdrückliche Bestätigung für das angezeigte Gerät und Konto.

Der statische Körper besteht aus 12 × 12 Farbregionen. Ein weißer Rahmen liegt außerhalb dieser Regionen, mit 4 % Breite je Seite. Vier verschiedenfarbige Eckregionen legen die Orientierung fest. Die oberen und unteren mittleren Regionen enthalten Cyan und Magenta als kalibrierbare Referenzen. Die Kamera liest jede Nutzregion relativ zu diesen Referenzen.

Die inneren 10 × 10 Regionen werden zeilenweise gelesen. Für jedes Bit gibt es zwei aufeinanderfolgende, inverse Farbregionen: Cyan/Magenta bedeutet 0, Magenta/Cyan bedeutet 1. Die ersten 96 Regionen enthalten 48 Bit, die letzten vier ein festes 0101-Prüfmuster. Die sechs Bytes sind:

1. `0xA1`: Version und Kennung.
2. Drei Bytes: numerischer Code, Big Endian, zulässiger Bereich 0…999999.
3. Zwei Bytes: CRC-16/CCITT-FALSE der ersten vier Bytes (Polynom `0x1021`, Startwert `0xFFFF`), Big Endian.

Die App zeigt führende Nullen an. Animation bewegt nur dekorative Partikel innerhalb ihrer festen Farbregionen. Reduce Motion deaktiviert diese Bewegung. Der Decoder prüft Orientierung, Referenzen, inverse Paare, Prüfmuster, Version, CRC und Wertebereich. Erst zwei übereinstimmende vollständige Lesungen innerhalb von 1,5 Sekunden lösen eine Anfrage an den Server aus. Der QR-Decoder akzeptiert ausschließlich `film://pair?code=######` ohne weitere URL-Teile; er navigiert keine URLs.

Die iPhone-Kamera verwendet AVFoundation, erkennt den quadratischen Rahmen mit Vision, korrigiert dessen Perspektive mit Core Image und mittelt neun Bildpunkte in der Mitte jeder Farbregion. Kamerabilder werden weder gespeichert noch übertragen. Die Kamera läuft nur bei geöffnetem Scanner. QR und manuelle Eingabe bleiben verfügbar, auch ohne Kamerazugriff.

Automatisch geprüft: Roundtrips für Grenzwerte und 1024 verschiedene Codes, führende Nullen, Vierteldrehungen, Helligkeits-/Weißabgleichsänderungen, beschädigte inverse Paare, CRC-Schäden, falsche Orientierung und ungültige QR-Marker. Der reine Swift-Client prüft JSON-Verträge, serverseitige Fehler und die Bestätigung von Rotation/Widerruf.

**Status:** experimenteller optischer Transport. Ein erfolgreicher synthetischer Test oder nativer Build bestätigt keine Zuverlässigkeit auf echten TVs. Abstand, Winkel, Umgebungslicht, HDR-/TV-Farbmodus und iPhone-Kamera müssen an echter Hardware geprüft werden.

Tests im eingeschränkten Arbeitsbereich:

```sh
CLANG_MODULE_CACHE_PATH=/tmp/film-light-modulecache swift test --disable-sandbox --package-path Packages/LightCode --scratch-path /tmp/film-lightcode-tests
```
