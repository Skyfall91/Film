import SwiftUI

struct AvatarArt: Identifiable, Hashable {
    let id: String
    let emoji: String
    let category: String
    let colorIndex: Int
    let hex: UInt32

    var color: Color {
        Color(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    /// Neue Figuren nur hinten anhängen: Die Nummer in der ID verweist auf gespeicherte Profile.
    static let categories: [(name: String, key: String, color: Int, emojis: [(String, UInt32)])] = [
        ("Science-Fiction", "scifi", 1, [("👽", 0x7ED957), ("🤖", 0x8FA8C8), ("🚀", 0xFF5A4E), ("🪐", 0xF2B25C),
                                         ("👾", 0xA779FF), ("🛸", 0x4FD1C5), ("🌌", 0x6C7BFF), ("☄️", 0xFF8A3D),
                                         ("🛰️", 0x7CC4E8), ("🌙", 0xF5D76E)]),
        ("Fantasy", "fantasy", 2, [("🐉", 0x3FBF7F), ("🧙", 0x8E6CFF), ("🦄", 0xFF8AD8), ("🧚", 0x6FE0C8),
                                   ("🧜", 0x3BC4E0), ("🔮", 0xB57BFF), ("🏰", 0xC2A878), ("🍄", 0xFF5F57),
                                   ("🗝️", 0xE8B04B), ("🌈", 0xFFB547)]),
        ("Grusel", "grusel", 4, [("👻", 0xB8C4D6), ("🧛", 0xE0384F), ("🎃", 0xFF8C2B), ("💀", 0xD9D2C3),
                                 ("🕷️", 0x7A5BD6), ("🧟", 0x8DBF4A), ("🦇", 0x9B59B6), ("🕯️", 0xF7C35C),
                                 ("🦉", 0xB08B5E), ("🌑", 0x7D8BA6)]),
        ("Abenteuer", "abenteuer", 0, [("🦖", 0x59C36A), ("🏴‍☠️", 0x9AA3AE), ("🦁", 0xF5A623), ("🦈", 0x4A90E2),
                                       ("🦅", 0xC8894A), ("🐺", 0x8796A8), ("🧭", 0xE9A23B), ("🌋", 0xFF6A3D),
                                       ("🏔️", 0x8EC9FF), ("🐊", 0x6BAF5A)]),
        ("Komödie", "komoedie", 5, [("🤡", 0xFF4D5E), ("🐵", 0xC68B59), ("🦆", 0xFFD23F), ("🐸", 0x6DD36D),
                                    ("🐧", 0x7FB8FF), ("🦥", 0xC9A27E), ("🍌", 0xFFE066), ("🦩", 0xFF7EB6),
                                    ("🐙", 0xFF7A6B), ("🤠", 0xE0A458)]),
        ("Kino-Snacks", "snacks", 5, [("🍿", 0xF4D35E), ("🍕", 0xFF9F43), ("🍩", 0xFF7EB6), ("🌮", 0xF7B267),
                                      ("🧁", 0xE58FD6), ("🍉", 0xFF5E6C), ("🥨", 0xC8894A), ("🍫", 0xB07A55)]),
        ("Für Kinder", "kinder", 3, [("🐻", 0xC98A5A), ("🐼", 0x7BDCB5), ("🐰", 0xFFA3C7), ("🦊", 0xFF8A3D),
                                     ("🐨", 0x9DB4D3), ("🐯", 0xFFB13D), ("🐶", 0xE3B27A), ("🐱", 0xFFC86B),
                                     ("🐷", 0xFF9EB5), ("🐥", 0xFFD84D), ("🐳", 0x5AB0FF), ("🦋", 0x6FA8FF)]),
    ]

    static let all: [AvatarArt] = categories.flatMap { c in
        c.emojis.enumerated().map {
            AvatarArt(id: "\(c.key)-\($0.offset)", emoji: $0.element.0, category: c.name, colorIndex: c.color, hex: $0.element.1)
        }
    }
    static func byID(_ id: String) -> AvatarArt? { all.first { $0.id == id } }
    static func inCategory(_ name: String) -> [AvatarArt] { all.filter { $0.category == name } }
}

/// Avatar als Kachel: Genre-Farbe, Figur in der Mitte.
