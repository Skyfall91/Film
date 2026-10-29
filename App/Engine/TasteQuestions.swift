import Foundation

/// Gezielte Frage im „KI beibringen“-Chat. Keine „Kennst du Film X?“-Fragen (das ist Swipen),
/// sondern Fragen danach, wie jemand Filme erlebt, jede Antwort wird in Merkmale übersetzt.
struct TasteQuestion: Identifiable, Equatable {
    struct Answer: Identifiable, Equatable {
        var label: String
        /// Änderung am Geschmacksprofil: Merkmal → Delta.
        var affinity: [String: Double] = [:]
        var id: String { label }
    }

    /// Wie geantwortet wird, damit der Chat nicht nur aus Entweder-oder besteht.
    enum Kind: Equatable {
        /// Eine Antwort antippen.
        case choice
        /// Mehrere Antworten wählen, dann „Weiter“.
        case multi
        /// Schieberegler zwischen zwei Polen; die Gewichte wirken je nach Position.
        case scale(low: String, high: String, weights: [String: Double])
        /// Freie Antwort. Genannte Filme werden mit diesem Signal gelernt.
        case open(filmSignal: Interaction)

        var family: String {
            switch self {
            case .choice: "choice"
            case .multi: "multi"
            case .scale: "scale"
            case .open: "open"
            }
        }
    }

    let id: String
    var text: String
    var answers: [Answer]
    var kind: Kind = .choice

    /// Alle Merkmale, über die diese Frage etwas verrät.
    var keys: Set<String> {
        var k = Set(answers.flatMap(\.affinity.keys))
        if case .scale(_, _, let w) = kind { k.formUnion(w.keys) }
        return k
    }
}

enum TasteQuestions {
    private static func q(_ id: String, _ text: String, _ answers: [(String, [String: Double])]) -> TasteQuestion {
        TasteQuestion(id: id, text: text, answers: answers.map { .init(label: $0.0, affinity: $0.1) })
    }

    private static func multi(_ id: String, _ text: String, _ answers: [(String, [String: Double])]) -> TasteQuestion {
        TasteQuestion(id: id, text: text, answers: answers.map { .init(label: $0.0, affinity: $0.1) }, kind: .multi)
    }
    private static func scale(_ id: String, _ text: String, _ low: String, _ high: String, _ w: [String: Double]) -> TasteQuestion {
        TasteQuestion(id: id, text: text, answers: [], kind: .scale(low: low, high: high, weights: w))
    }
    private static func open(_ id: String, _ text: String, _ signal: Interaction) -> TasteQuestion {
        TasteQuestion(id: id, text: text, answers: [], kind: .open(filmSignal: signal))
    }

    /// Kreativere Fragen: Film selbst zusammenbauen, Gedankenspiele, Bauchgefühl.
    static let creative: [TasteQuestion] = [
        multi("c-baukasten", "Bau dir deinen Film für heute Abend. Was kommt rein?", [
            ("Ein Heist", ["g:Krimi": 0.8, "m:wendungsreich": 0.8]), ("Zeitreise", ["g:Science-Fiction": 1.0, "m:wendungsreich": 0.6]),
            ("Erste Liebe", ["m:romantisch": 1.0, "m:gefühlvoll": 0.4]), ("Ein Roadtrip", ["g:Abenteuer": 1.0, "m:leicht": 0.4]),
            ("Ein Geisterhaus", ["m:gruselig": 1.2, "g:Horror": 0.6]), ("Ein Underdog", ["m:inspirierend": 1.2, "g:Sport": 0.6]),
            ("Ein Komplott", ["g:Thriller": 1.0, "m:spannend": 0.6]), ("Sprechende Tiere", ["g:Animation": 1.0, "m:familienfreundlich": 0.8])]),
        multi("c-soundtrack", "Welcher Soundtrack läuft in deinem Lieblingsfilm?", [
            ("Großes Orchester", ["m:episch": 1.2, "m:bildgewaltig": 0.6]), ("Synthesizer", ["g:Science-Fiction": 0.6, "m:düster": 0.6]),
            ("Alte Popsongs", ["m:leicht": 0.8, "m:lustig": 0.4]), ("Fast nur Stille", ["m:ruhig": 1.2, "m:nachdenklich": 0.6]),
            ("Musical-Nummern", ["m:musikalisch": 1.4, "g:Musical": 0.8]), ("Dröhnende Bässe", ["m:actionreich": 1.0, "m:intensiv": 0.6])]),
        multi("c-figur", "Welche Hauptfigur würdest du zwei Stunden lang begleiten?", [
            ("Ein Genie mit Macken", ["m:schräg": 0.8, "g:Biografie": 0.6]), ("Eine Antiheldin", ["m:düster": 0.8, "m:intensiv": 0.6]),
            ("Ein Kind auf Abenteuer", ["m:familienfreundlich": 1.0, "g:Abenteuer": 0.6]), ("Ein müder Ermittler", ["g:Krimi": 1.2, "m:düster": 0.4]),
            ("Eine Gruppe Freunde", ["m:lustig": 0.8, "m:leicht": 0.6]), ("Ein Roboter", ["g:Science-Fiction": 1.2, "m:gefühlvoll": 0.4])]),
        multi("c-epoche", "Durch welche Zeit würdest du dich gern führen lassen?", [
            ("Antike", ["g:Historie": 1.0, "m:episch": 0.6]), ("Mittelalter", ["g:Fantasy": 0.6, "g:Historie": 0.6]),
            ("Wilde Zwanziger", ["g:Drama": 0.6, "m:musikalisch": 0.4]), ("Weltkriege", ["g:Krieg": 1.2, "m:intensiv": 0.6]),
            ("Die 80er", ["m:bunt": 0.8, "m:leicht": 0.4]), ("Ferne Zukunft", ["g:Science-Fiction": 1.2])]),
        multi("c-snacks", "Kino-Ritual: Was gehört für dich dazu?", [
            ("Popcorn & Krach", ["m:actionreich": 0.8, "g:Action": 0.4]), ("Decke & Tee", ["m:gemütlich": 1.2, "m:ruhig": 0.4]),
            ("Licht aus, Handy weg", ["m:intensiv": 0.6, "m:nachdenklich": 0.6]), ("Freunde zum Mitreden", ["m:lustig": 0.8]),
            ("Taschentücher", ["m:gefühlvoll": 1.0])]),
        scale("s-farben", "Wie soll dein Film aussehen?", "Grau und rau", "Knallbunt",
              ["m:bunt": 1.2, "m:düster": -0.8]),
        scale("s-realismus", "Wie nah an der Wirklichkeit?", "Könnte morgen passieren", "Pure Fantasie",
              ["g:Fantasy": 1.0, "g:Science-Fiction": 0.6, "g:Drama": -0.6]),
        scale("s-kopf", "Kopf oder Bauch?", "Lass mich nachdenken", "Lass mich fühlen",
              ["m:gefühlvoll": 1.0, "m:nachdenklich": -0.8]),
        scale("s-laenge", "Wie lang darf es werden?", "90 Minuten, zack", "Gern drei Stunden",
              ["m:episch": 1.2, "m:leicht": -0.4]),
        scale("s-humor", "Wie viel Humor brauchst du, selbst in ernsten Filmen?", "Ernst bleibt ernst", "Immer ein Witz",
              ["m:lustig": 1.2, "m:intensiv": -0.4]),
        scale("s-gross", "Wie groß soll die Geschichte sein?", "Ein Zimmer, zwei Menschen", "Das Schicksal der Galaxie",
              ["m:episch": 1.2, "m:bildgewaltig": 0.6, "m:ruhig": -0.6]),
        open("o-leben", "Wenn dein Leben ein Film wäre, welcher käme dem am nächsten?", .liked),
        open("o-ueberschaetzt", "Welcher gefeierte Film hat dich komplett kaltgelassen?", .disliked),
        open("o-kindheit", "Welchen Film hast du als Kind rauf und runter geschaut?", .liked),
        open("o-insel", "Einsame Insel, ein einziger Film. Welcher?", .loved),
        open("o-nochmal", "Welchen Film würdest du gern nochmal zum ersten Mal sehen?", .loved),
        q("c-zeitmaschine", "Du darfst in einen Film hineinspringen, aber nur als Statist. Wohin?", [
            ("Auf ein Raumschiff", ["g:Science-Fiction": 1.2]), ("Auf einen Ball im 19. Jahrhundert", ["g:Historie": 0.8, "m:romantisch": 0.8]),
            ("In eine Bar voller Gangster", ["g:Krimi": 1.0, "m:düster": 0.4]), ("Ins Zauberschloss", ["g:Fantasy": 1.2, "m:familienfreundlich": 0.4])]),
        q("c-plottwist", "Plot-Twist in der letzten Minute: Alles war ein Traum.", [
            ("Genial, wenn's clever ist", ["m:wendungsreich": 1.2, "g:Mystery": 0.6]), ("Billigster Trick überhaupt", ["m:wendungsreich": -0.8]),
            ("Hauptsache, die Reise war schön", ["m:bildgewaltig": 0.6, "m:gefühlvoll": 0.4])]),
        q("c-spoiler", "Jemand spoilert dir das Ende. Wie schlimm?", [
            ("Katastrophe!", ["m:wendungsreich": 1.0, "m:spannend": 0.6]), ("Mir egal, es geht um den Weg", ["m:ruhig": 0.6, "m:bildgewaltig": 0.6])]),
        q("c-remake", "Ein Klassiker bekommt ein Remake. Dein erster Gedanke?", [
            ("Endlich in schön", ["m:bildgewaltig": 0.8, "m:actionreich": 0.4]), ("Lasst das Original in Ruhe", ["m:nachdenklich": 0.6, "m:ruhig": 0.4]),
            ("Hauptsache, jemand macht's anders", ["m:schräg": 1.0])]),
        q("c-untertitel", "Ein koreanischer Film mit Untertiteln. Und?", [
            ("Her damit", ["m:schräg": 0.6, "m:intensiv": 0.6, "m:nachdenklich": 0.4]), ("Ich will mich zurücklehnen", ["m:leicht": 0.8, "m:gemütlich": 0.4])]),
        q("c-langsam", "Die ersten 30 Minuten passiert kaum etwas, dann explodiert alles.", [
            ("Das beste Gefühl", ["m:intensiv": 0.8, "m:spannend": 0.8, "m:ruhig": 0.4]), ("Nach 10 Minuten bin ich weg", ["m:actionreich": 0.8, "m:ruhig": -0.8])]),
        q("c-tier", "Im Film stirbt ein Hund.", [
            ("Abbruch, sofort", ["m:familienfreundlich": 0.6, "m:gefühlvoll": -0.6, "m:intensiv": -0.8]),
            ("Wenn es zur Geschichte gehört", ["m:gefühlvoll": 0.6, "m:intensiv": 0.4])]),
        q("c-dialog", "Was bleibt bei dir länger hängen?", [
            ("Ein Satz", ["m:nachdenklich": 1.0]), ("Ein Bild", ["m:bildgewaltig": 1.2]), ("Ein Song", ["m:musikalisch": 1.2]), ("Ein Gefühl", ["m:gefühlvoll": 1.2])]),
        q("c-sport", "Das große Finale, die letzte Sekunde, das ganze Stadion hält die Luft an.", [
            ("Ich stehe vom Sofa auf", ["g:Sport": 1.2, "m:inspirierend": 1.0]), ("Sport im Film? Gähn", ["g:Sport": -1.2])]),
        q("c-dokustil", "Ein Film, der aussieht wie eine echte Doku: wackelige Kamera, keine Stars.", [
            ("Fühlt sich echt an", ["m:intensiv": 0.8, "g:Drama": 0.6]), ("Ich will Kino, kein Handyvideo", ["m:bildgewaltig": 0.8, "m:episch": 0.4])]),
        q("c-familie", "Filmabend mit der ganzen Familie, von 8 bis 80. Was läuft?", [
            ("Ein Animationsfilm", ["g:Animation": 1.0, "m:familienfreundlich": 1.0]), ("Ein großes Abenteuer", ["g:Abenteuer": 1.0, "m:episch": 0.4]),
            ("Eine Komödie", ["g:Komödie": 1.0, "m:lustig": 0.6]), ("Familienabend? Ohne mich", ["m:familienfreundlich": -1.0])]),
        q("c-krieg", "Kriegsfilme: wichtig oder zu schwer?", [
            ("Wichtig, gerade weil sie wehtun", ["g:Krieg": 1.2, "m:intensiv": 0.8]), ("Zu schwer für einen Filmabend", ["g:Krieg": -1.2, "m:leicht": 0.6])]),
        q("c-zweiter", "Ein Film, den man zweimal sehen muss, um ihn zu verstehen.", [
            ("Das sind die besten", ["m:wendungsreich": 1.2, "m:nachdenklich": 0.8]), ("Einmal muss reichen", ["m:leicht": 0.8, "m:wendungsreich": -0.6])]),
        q("c-wohlfuehl", "Dein Wohlfühlfilm ist …", [
            ("… zum Mitsingen", ["m:musikalisch": 1.0, "m:leicht": 0.6]), ("… zum Wegträumen", ["m:romantisch": 0.8, "m:bildgewaltig": 0.6]),
            ("… zum Lachen", ["m:lustig": 1.2]), ("… ehrlich gesagt ein Thriller", ["g:Thriller": 1.0, "m:spannend": 0.8])])
    ]

    /// Fragen mit Mehrfachauswahl, Schieberegler und freier Antwort.
    static let varied: [TasteQuestion] = [
        multi("m-packt", "Was packt dich an einem Film am meisten? Wähl ruhig mehrere.", [
            ("Die Bilder", ["m:bildgewaltig": 1.2]), ("Die Musik", ["m:musikalisch": 1.2]),
            ("Die Dialoge", ["m:nachdenklich": 0.8, "m:ruhig": 0.4]), ("Die Spannung", ["m:spannend": 1.2]),
            ("Die Figuren", ["m:gefühlvoll": 1.0]), ("Die Twists", ["m:wendungsreich": 1.2]),
            ("Der Humor", ["m:lustig": 1.2])]),
        multi("m-fehlen", "Was darf in deinem perfekten Film auf keinen Fall fehlen?", [
            ("Eine Verfolgungsjagd", ["m:actionreich": 1.2]), ("Ein Kuss", ["m:romantisch": 1.2]),
            ("Ein Monster", ["m:gruselig": 1.0, "g:Horror": 0.6]), ("Ein Raumschiff", ["g:Science-Fiction": 1.2]),
            ("Ein Schwert", ["g:Fantasy": 1.0, "m:episch": 0.4]), ("Eine Leiche", ["g:Krimi": 1.0, "g:Mystery": 0.6]),
            ("Ein Song", ["m:musikalisch": 1.0]), ("Ein Hund", ["m:familienfreundlich": 0.8, "m:gemütlich": 0.4])]),
        multi("m-orte", "An welche Orte lässt du dich gern entführen?", [
            ("Ins Weltall", ["g:Science-Fiction": 1.2]), ("In eine Kleinstadt", ["m:ruhig": 0.8, "g:Drama": 0.6]),
            ("Großstadt bei Nacht", ["m:düster": 0.8, "g:Thriller": 0.8]), ("In die Wüste", ["m:episch": 0.8, "m:bildgewaltig": 0.8]),
            ("In einen Märchenwald", ["g:Fantasy": 1.0, "m:familienfreundlich": 0.4]), ("In ein einziges Haus", ["m:intensiv": 0.8, "g:Mystery": 0.8]),
            ("In die Vergangenheit", ["g:Historie": 1.0, "g:Biografie": 0.6])]),
        scale("s-puls", "Wie viel Anspannung hältst du aus?", "Puls bitte niedrig", "Bis ich nicht mehr atme",
              ["m:spannend": 1.0, "m:intensiv": 0.8, "m:gemütlich": -0.8]),
        scale("s-traenen", "Wie traurig darf ein Film werden?", "Bitte gar nicht", "Ich will weinen",
              ["m:gefühlvoll": 1.2, "m:leicht": -0.6]),
        scale("s-verrueckt", "Wie verrückt darf eine Geschichte sein?", "Bodenständig", "Völlig durchgeknallt",
              ["m:schräg": 1.2, "m:wendungsreich": 0.4]),
        scale("s-blut", "Wie viel Blut ist okay?", "Keinen Tropfen", "Kein Problem",
              ["m:intensiv": 1.0, "g:Horror": 0.6, "m:familienfreundlich": -0.6]),
        scale("s-tempo", "Welches Tempo magst du?", "Langsam und ruhig", "Vollgas",
              ["m:actionreich": 1.0, "m:ruhig": -1.0]),
        open("o-umgehauen", "Welcher Film hat dich zuletzt richtig umgehauen, und warum?", .loved),
        open("o-erklaeren", "Welchen Film würdest du jemandem zeigen, um zu erklären, wer du bist?", .loved),
        open("o-eingeschlafen", "Bei welchem Film bist du eingeschlafen, oder hättest es gern?", .disliked),
        open("o-szene", "Welche Filmszene geht dir einfach nicht mehr aus dem Kopf?", .liked)
    ]

    static let all: [TasteQuestion] = varied + creative + curated

    static let curated: [TasteQuestion] = [
        q("offen", "Ein Film endet offen und du grübelst noch tagelang. Genial oder nervig?", [
            ("Genial", ["m:nachdenklich": 1.2, "m:wendungsreich": 0.6]),
            ("Nervig", ["m:nachdenklich": -1.0, "m:leicht": 0.8]),
            ("Kommt drauf an", [:])]),
        q("traurig", "Darf ein Film dich traurig zurücklassen?", [
            ("Unbedingt", ["m:gefühlvoll": 1.2, "m:intensiv": 0.6]),
            ("Lieber nicht", ["m:gefühlvoll": -0.8, "m:leicht": 1.0, "m:gemütlich": 0.6])]),
        q("abend", "Langer Tag hinter dir. Was rettet den Abend?", [
            ("Was zum Lachen", ["m:lustig": 1.2, "m:leicht": 0.8]),
            ("Was Spannendes", ["m:spannend": 1.2, "m:wendungsreich": 0.6]),
            ("Was zum Staunen", ["m:bildgewaltig": 1.2, "m:episch": 0.6])]),
        q("gaensehaut", "Wie viel Gänsehaut verträgst du?", [
            ("Je mehr, desto besser", ["m:gruselig": 1.5, "g:Horror": 1.2]),
            ("Ein bisschen Nervenkitzel", ["m:spannend": 1.0, "m:gruselig": 0.2]),
            ("Gar keine", ["m:gruselig": -1.5, "g:Horror": -1.5])]),
        q("welten", "Was zieht dich mehr rein: eine Welt, die es nicht gibt, oder eine Geschichte, die so passiert sein könnte?", [
            ("Fremde Welten", ["g:Science-Fiction": 1.0, "g:Fantasy": 1.0, "m:episch": 0.6]),
            ("Echtes Leben", ["g:Drama": 1.0, "m:nachdenklich": 0.6, "m:ruhig": 0.4]),
            ("Beides", ["g:Science-Fiction": 0.4, "g:Drama": 0.4])]),
        q("krachen", "Wie wichtig ist dir, dass es ordentlich kracht?", [
            ("Sehr", ["m:actionreich": 1.5, "g:Action": 1.0]),
            ("Muss nicht sein", ["m:actionreich": -0.6, "m:ruhig": 0.6]),
            ("Lieber gar nicht", ["m:actionreich": -1.5, "g:Action": -1.0])]),
        q("schraeg", "Darf ein Film richtig schräg und eigenwillig sein?", [
            ("Je eigener, desto besser", ["m:schräg": 1.4]),
            ("Lieber klassisch erzählt", ["m:schräg": -1.2])]),
        q("liebe", "Liebesgeschichte im Film: Herzstück oder Nebensache?", [
            ("Herzstück", ["m:romantisch": 1.5, "g:Romanze": 1.0]),
            ("Nebensache", ["m:romantisch": -0.4]),
            ("Bitte ohne", ["m:romantisch": -1.2, "g:Romanze": -1.0])]),
        q("animation", "Animationsfilme: nur was für Kinder?", [
            ("Nein, oft die besten", ["g:Animation": 1.5, "m:bunt": 0.6]),
            ("Ab und zu gern", ["g:Animation": 0.5]),
            ("Eher nicht meins", ["g:Animation": -1.2])]),
        q("musik", "Jemand fängt im Film an zu singen. Du bist …", [
            ("… sofort dabei", ["m:musikalisch": 1.5, "g:Musical": 1.0]),
            ("… raus", ["m:musikalisch": -1.2, "g:Musical": -1.5])]),
        q("ueberraschung", "Überrascht werden oder wissen, was du bekommst?", [
            ("Überrasch mich", ["m:wendungsreich": 1.2, "m:schräg": 0.5]),
            ("Ich weiß gern, was kommt", ["m:gemütlich": 1.0, "m:familienfreundlich": 0.4])]),
        q("krimi", "Ein düsterer Krimi am Sonntagabend?", [
            ("Perfekt", ["m:düster": 1.0, "g:Krimi": 1.0, "g:Thriller": 0.6]),
            ("Zu schwer für Sonntag", ["m:düster": -1.0, "m:leicht": 0.6])]),
        q("hart", "Filme, die richtig wehtun: Gewalt, harte Themen?", [
            ("Wenn's gut gemacht ist, ja", ["m:intensiv": 1.2, "m:düster": 0.6]),
            ("Lieber nicht", ["m:intensiv": -1.2, "m:gemütlich": 0.6])]),
        q("gross", "Drei Stunden Epos auf der großen Leinwand: Vorfreude oder Respekt?", [
            ("Vorfreude", ["m:episch": 1.4, "m:bildgewaltig": 0.8]),
            ("Respekt", ["m:episch": -0.8, "m:leicht": 0.4])]),
        q("reden", "Zwei Stunden lang reden nur zwei Menschen miteinander. Spannend oder Folter?", [
            ("Spannend", ["m:ruhig": 1.2, "m:nachdenklich": 1.0]),
            ("Folter", ["m:ruhig": -1.0, "m:actionreich": 0.6])]),
        q("boesewicht", "Am Ende merkst du: Der Bösewicht hatte eigentlich recht. Großartig oder unbefriedigend?", [
            ("Großartig", ["m:nachdenklich": 0.8, "m:intensiv": 0.6, "m:wendungsreich": 0.6]),
            ("Unbefriedigend", ["m:familienfreundlich": 0.6, "m:leicht": 0.6])]),
        q("aufwachen", "Du wachst in einem Film auf. Welches Genre bitte auf keinen Fall?", [
            ("Horror", ["m:gruselig": -1.5, "g:Horror": -1.2]),
            ("Musical", ["m:musikalisch": -1.2, "g:Musical": -1.2]),
            ("Liebesdrama", ["m:romantisch": -1.2, "g:Romanze": -0.8]),
            ("Weltraum", ["g:Science-Fiction": -1.2])]),
        q("echt", "Abspann. Und du weißt nicht, was davon echt war. Und jetzt?", [
            ("Sofort nochmal schauen", ["m:wendungsreich": 1.4, "g:Mystery": 1.0]),
            ("Ich brauche Antworten", ["m:wendungsreich": -0.6, "m:leicht": 0.4])]),
        q("taschentuch", "Wie viele Taschentücher darf ein guter Film kosten?", [
            ("Eine ganze Packung", ["m:gefühlvoll": 1.5, "g:Drama": 0.6]),
            ("Ein, zwei", ["m:gefühlvoll": 0.5]),
            ("Keins, bitte", ["m:gefühlvoll": -1.0, "m:lustig": 0.6])]),
        q("landschaft", "Die Kamera gleitet minutenlang über eine Landschaft. Sonst passiert nichts.", [
            ("Gänsehaut", ["m:bildgewaltig": 1.4, "m:ruhig": 0.8]),
            ("Vorspulen", ["m:bildgewaltig": -0.6, "m:actionreich": 0.6])]),
        q("lachen", "Du lachst laut im Kino und alle drehen sich um. Passiert dir das?", [
            ("Ständig", ["m:lustig": 1.4, "g:Komödie": 1.0]),
            ("Eher selten", ["m:lustig": -0.5, "m:nachdenklich": 0.4])]),
        q("absurd", "Ein Film, der sich selbst kein bisschen ernst nimmt?", [
            ("Je absurder, desto besser", ["m:schräg": 1.2, "m:lustig": 0.8]),
            ("Bitte mit Haltung", ["m:schräg": -0.8, "m:intensiv": 0.4])]),
        q("abendgast", "Raumschiff, Drache oder Detektiv: Wer bekommt deinen Abend?", [
            ("Raumschiff", ["g:Science-Fiction": 1.4]),
            ("Drache", ["g:Fantasy": 1.4]),
            ("Detektiv", ["g:Krimi": 1.2, "g:Mystery": 0.8])]),
        q("danach", "Nach dem Film: lieber stundenlang diskutieren oder einfach gute Laune haben?", [
            ("Diskutieren", ["m:nachdenklich": 1.2]),
            ("Gute Laune", ["m:leicht": 1.2, "m:lustig": 0.6])]),
        q("monster", "Ein Monster, das man nie richtig zu sehen bekommt.", [
            ("Viel gruseliger so", ["m:gruselig": 1.2, "g:Horror": 0.8, "m:spannend": 0.6]),
            ("Zeig es mir endlich", ["m:actionreich": 0.6]),
            ("Ohne mich", ["m:gruselig": -1.2])]),
        q("schwarzweiss", "Drei Stunden, schwarz-weiß, kaum Musik.", [
            ("Klingt nach Meisterwerk", ["m:nachdenklich": 0.8, "m:episch": 0.8, "m:ruhig": 0.6]),
            ("Klingt nach Hausaufgaben", ["m:leicht": 0.8, "m:ruhig": -0.6])]),
        q("heist", "Ein Raubzug-Film. Wofür bist du eigentlich da?", [
            ("Für den genialen Plan", ["m:wendungsreich": 1.2, "g:Krimi": 0.6]),
            ("Für die Verfolgungsjagd", ["m:actionreich": 1.2]),
            ("Für die chaotische Truppe", ["m:lustig": 0.8, "m:schräg": 0.4])]),
        q("pixar", "Schon mal bei einem Animationsfilm geweint?", [
            ("Mehr als einmal", ["g:Animation": 1.2, "m:gefühlvoll": 0.8]),
            ("Nie", ["g:Animation": -0.6])]),
        q("kitsch", "Wie viel Kitsch verträgt eine Liebesgeschichte?", [
            ("Je mehr, desto schöner", ["m:romantisch": 1.4, "m:gemütlich": 0.6]),
            ("Ein bisschen", ["m:romantisch": 0.4]),
            ("Null", ["m:romantisch": -1.2])]),
        q("zusammenzucken", "Der ganze Kinosaal zuckt gleichzeitig zusammen. Dein Lieblingsmoment?", [
            ("Absolut", ["m:gruselig": 1.0, "m:spannend": 1.0]),
            ("Eher nicht", ["m:gruselig": -1.0])]),
        q("wahregeschichte", "Nach einer wahren Geschichte: spannender als jede Fiktion?", [
            ("Oft ja", ["g:Biografie": 1.2, "g:Historie": 1.0, "g:Drama": 0.6]),
            ("Lieber erfunden", ["g:Fantasy": 0.6, "g:Biografie": -0.8])]),
        q("familienstreit", "Eine Familie, ein Haus, ein Wochenende voller Streit.", [
            ("Klingt perfekt", ["g:Drama": 1.0, "m:intensiv": 0.6, "m:lustig": 0.4]),
            ("Hab ich zu Hause", ["m:leicht": 0.6, "g:Drama": -0.6])]),
        q("kinderhelden", "Kinder als Hauptfiguren, die die Welt retten?", [
            ("Rührend", ["m:familienfreundlich": 1.2, "m:inspirierend": 0.6]),
            ("Anstrengend", ["m:familienfreundlich": -1.0])]),
        q("ende", "Du dürftest das Ende eines traurigen Films umschreiben. Machst du's?", [
            ("Nein, es gehört so", ["m:nachdenklich": 0.8, "m:intensiv": 0.4]),
            ("Klar, Happy End!", ["m:leicht": 1.0, "m:gemütlich": 0.6])]),
        q("superheld", "Der 34. Superheldenfilm kommt raus. Noch Lust?", [
            ("Immer", ["m:actionreich": 1.0, "g:Action": 0.8, "m:episch": 0.4]),
            ("Langsam satt", ["m:actionreich": -0.4, "m:schräg": 0.6, "m:nachdenklich": 0.4])]),
        q("mutmacher", "Ein Film, nach dem du am liebsten sofort dein Leben änderst?", [
            ("Genau mein Ding", ["m:inspirierend": 1.4, "g:Biografie": 0.4]),
            ("Zu viel Pathos", ["m:inspirierend": -1.0, "m:schräg": 0.4])])
    ]

    /// Die Frage, über deren Merkmale das Profil am wenigsten weiß.
    static func next(for profile: Profile, asked: Set<String>) -> TasteQuestion? {
        // Demo-Schalter (Startparameter -skipCuratedQuestions YES): gleich Situationsfragen zeigen.
        if UserDefaults.standard.bool(forKey: "skipCuratedQuestions") { return nil }
        // Demo-Schalter (-chatQuestion <id>): mit einer bestimmten Frage starten.
        if let forced = UserDefaults.standard.string(forKey: "chatQuestion"), !asked.contains(forced),
           let q = all.first(where: { $0.id == forced }) { return q }
        func certainty(_ q: TasteQuestion) -> Double {
            let k = q.keys
            let base = k.map { abs(profile.affinity[$0] ?? 0) }.reduce(0, +) / Double(max(k.count, 1))
            // Personenfragen nicht gleich zu Beginn, erst ein Gefühl für Stimmungen bekommen.
            return q.id.hasPrefix("pd") || q.id.hasPrefix("pc") ? base + 0.6 : base
        }
        // Namen nur dosiert: höchstens eine Personenfrage pro sechs anderen Fragen, nie zweimal
        // hintereinander, insgesamt höchstens vier, sonst wird der Chat zur Besetzungsliste.
        let peopleAsked = asked.filter { $0.hasPrefix("pd") || $0.hasPrefix("pc") }.count
        let othersAsked = asked.count - peopleAsked
        let lastWasPerson = lastAsked.map { $0.hasPrefix("pd") || $0.hasPrefix("pc") } ?? false
        let peopleAllowed = !lastWasPerson && peopleAsked < 4 && othersAsked >= 6 * (peopleAsked + 1)
        let candidates = all + (peopleAllowed ? peopleQuestions(asked: asked) : [])
        // Offene Fragen verraten keine festen Merkmale, mittlere Priorität geben.
        func priority(_ q: TasteQuestion) -> Double {
            if case .open = q.kind { return 0.5 }
            return certainty(q)
        }
        let ranked = candidates.filter { !asked.contains($0.id) }.sorted { priority($0) < priority($1) }
        // Abwechslung: möglichst nicht zweimal hintereinander dieselbe Art von Frage.
        let lastKind = lastAsked.flatMap { id in candidates.first { $0.id == id } ?? all.first { $0.id == id } }?.kind.family
        return ranked.prefix(6).first { $0.kind.family != lastKind } ?? ranked.first
    }

    /// Zuletzt gestellte Frage, für die Abwechslung der Fragearten.
    static var lastAsked: String?

    /// Filme aus dem Katalog, die in einem Text genannt werden (deutscher oder Originaltitel).
    static func films(in text: String) -> [Film] {
        let t = text.lowercased()
        return FilmIndex.all.filter { film in
            [film.title, film.originalTitle].contains { title in
                let lower = title.lowercased()
                guard lower.count >= 4 else { return false }
                return t.firstMatch(of: try! Regex("\\b\(NSRegularExpression.escapedPattern(for: lower))\\b")) != nil
            }
        }
    }

    // MARK: Regie & Schauspiel

    /// Personen, die im Katalog mehrfach vorkommen, nach Häufigkeit.
    static let directors: [String] = ranked(FilmIndex.all.map(\.director))
    static let actors: [String] = ranked(FilmIndex.all.flatMap { $0.cast.prefix(3) })

    private static func ranked(_ names: [String]) -> [String] {
        let counts = Dictionary(names.filter { !$0.isEmpty }.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.filter { $0.value >= 2 }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    /// Je eine Regie- und eine Schauspielfrage; danach die nächsten vier Namen.
    private static func peopleQuestions(asked: Set<String>) -> [TasteQuestion] {
        func page(_ prefix: String, _ names: [String], _ text: String, _ key: String) -> TasteQuestion? {
            let n = asked.filter { $0.hasPrefix(prefix) }.count
            let slice = names.dropFirst(n * 4).prefix(4)
            guard slice.count >= 2 else { return nil }
            return TasteQuestion(id: "\(prefix)\(n)", text: text,
                                 answers: slice.map { .init(label: $0, affinity: ["\(key):\($0)": 2.5]) }
                                    + [.init(label: "Niemand davon", affinity: [:])])
        }
        return [
            page("pd", directors, "Bei wessen Filmen bist du sofort dabei?", "d"),
            page("pc", actors, "Für wen schaust du dir fast jeden Film an?", "c")
        ].compactMap { $0 }
    }

    /// Namen aus freiem Text: „alles von Villeneuve“, „kein Dwayne Johnson“.
    /// Erkennt volle Namen und eindeutige Nachnamen.
    static func people(in text: String) -> [(key: String, name: String)] {
        let t = text.lowercased()
        let all = directors.map { ("d", $0) } + FilmIndex.all.flatMap { $0.cast.prefix(3) }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.map { ("c", $0) }
            + FilmIndex.all.map(\.director).reduce(into: [String]()) { if !$0.contains($1) && !$1.isEmpty { $0.append($1) } }.filter { !directors.contains($0) }.map { ("d", $0) }
        var found: [(String, String)] = []
        for (kind, name) in all {
            let last = name.split(separator: " ").last.map(String.init)?.lowercased() ?? ""
            if t.contains(name.lowercased()) || (last.count >= 5 && t.firstMatch(of: try! Regex("\\b\(NSRegularExpression.escapedPattern(for: last))\\b")) != nil) {
                if !found.contains(where: { $0.1 == name }) { found.append(("\(kind):\(name)", name)) }
            }
        }
        return found.map { (key: $0.0, name: $0.1) }
    }
}

// MARK: - Gemerkte Fragen (pro Profil, über Sitzungen hinweg)

extension TasteQuestions {
    private static func key(_ profileID: UUID) -> String { "askedQuestions.\(profileID.uuidString)" }

    static func asked(for profileID: UUID) -> [String] {
        UserDefaults.standard.stringArray(forKey: key(profileID)) ?? []
    }

    static func remember(_ question: TasteQuestion, for profileID: UUID) {
        lastAsked = question.id
        var list = asked(for: profileID)
        guard !list.contains(question.id) else { return }
        list.append(question.id)
        UserDefaults.standard.set(list, forKey: key(profileID))
    }
}
