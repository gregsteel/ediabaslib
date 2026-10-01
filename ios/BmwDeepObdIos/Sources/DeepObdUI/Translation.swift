import Foundation
import SwiftUI
#if canImport(Translation)
import Translation
#endif

/// Standard BMW fault status phrases (table FARTTEXTE of the SGBDs) with fixed English wording.
enum Glossary {
    static let phrases: [String: String] = [
        "kein passendes fehlersymptom": "no matching fault symptom",
        "signal oder wert oberhalb schwelle": "signal or value above threshold",
        "signal oder wert unterhalb schwelle": "signal or value below threshold",
        "kein signal oder wert": "no signal or value",
        "unplausibles signal oder wert": "implausible signal or value",
        "testbedingungen erfüllt": "test conditions met",
        "testbedingungen noch nicht erfüllt": "test conditions not yet met",
        "fehler bisher nicht aufgetreten": "fault has not occurred so far",
        "fehler momentan nicht vorhanden, aber bereits gespeichert": "fault not present at the moment, but already stored",
        "fehler momentan vorhanden, aber noch nicht gespeichert (entprellphase)": "fault present at the moment, but not stored yet (debounce phase)",
        "fehler momentan vorhanden und bereits gespeichert": "fault present at the moment and already stored",
        "fehler würde das aufleuchten einer warnlampe verursachen": "fault would cause a warning lamp to light up",
        "fehler würde kein aufleuchten einer warnlampe verursachen": "fault would not cause a warning lamp to light up",
        "unbekannte fehlerart": "unknown fault type",
        "unbekannter fehlerort": "unknown fault location",
        "okay, wenn fehlerfrei": "OKAY if no error",
    ]

    static func english(_ s: String) -> String? {
        var key = s.trimmingCharacters(in: .whitespaces).lowercased()
        // unknown-location placeholders look like "XYXY  Unbekannter Fehlerort"
        if key.hasPrefix("xyxy") { key = String(key.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
        return phrases[key]
    }
}

/// Rough English reading of BMW job names such as STATUS_MESSWERTBLOCK_LESEN.
enum JobNameGlossary {
    static let tokens: [String: String] = [
        "FS": "fault memory", "FEHLER": "fault", "FEHLERSPEICHER": "fault memory", "LESEN": "read", "LOESCHEN": "clear",
        "STATUS": "status", "STEUERN": "control", "IDENT": "identification", "IDENTIFIKATION": "identification",
        "SG": "control unit", "ABGLEICH": "adaptation", "MESSWERTBLOCK": "measured value block",
        "MESSWERTE": "measured values", "MESSWERT": "measured value", "SPEICHER": "memory", "SCHREIBEN": "write",
        "SETZEN": "set", "RUECKSETZEN": "reset", "RESET": "reset", "INITIALISIERUNG": "initialisation", "ENDE": "end",
        "INFO": "info", "DIAGNOSE": "diagnosis", "SERVICE": "service", "CODIEREN": "code", "CODIERUNG": "coding",
        "VARIANTE": "variant", "KOMPONENTE": "component", "MOTOR": "engine", "GETRIEBE": "transmission",
        "BATTERIE": "battery", "TEMPERATUR": "temperature", "DRUCK": "pressure", "DREHZAHL": "engine speed",
        "EINSPRITZUNG": "injection", "ABGAS": "exhaust", "KRAFTSTOFF": "fuel", "OEL": "oil", "KUEHLMITTEL": "coolant",
        "LUFT": "air", "SENSOR": "sensor", "STELLER": "actuator", "REGELUNG": "control loop", "TEST": "test",
        "PRUEFEN": "check", "ANZEIGE": "display", "UMWELT": "environment", "ART": "type", "ORT": "location",
        "ZAEHLER": "counter", "KILOMETER": "mileage", "DATUM": "date", "ZEIT": "time", "SCHALTER": "switch",
        "TASTER": "button", "LAMPE": "lamp", "LICHT": "light", "TUER": "door", "FENSTER": "window",
        "SCHLOSS": "lock", "SITZ": "seat", "SPIEGEL": "mirror", "WISCHER": "wiper", "HEIZUNG": "heating",
        "KLIMA": "climate", "DACH": "roof", "LERNWERTE": "learned values", "ANLERNEN": "teach in",
        "ZUENDUNG": "ignition", "GLUEHEN": "glow", "PARTIKELFILTER": "particulate filter", "REGENERATION": "regeneration",
        "TURBO": "turbo", "LADEDRUCK": "boost pressure", "DREHMOMENT": "torque", "LEERLAUF": "idle",
        "NOCKENWELLE": "camshaft", "KURBELWELLE": "crankshaft", "ZYLINDER": "cylinder", "VENTIL": "valve",
        "PUMPE": "pump", "KLAPPE": "flap", "AGR": "EGR", "EWS": "immobiliser", "SCHLUESSEL": "key",
        "BREMSE": "brake", "LENKUNG": "steering", "RAD": "wheel", "REIFEN": "tyre", "GESCHWINDIGKEIT": "speed",
        "ZUSTAND": "state", "AKTIV": "active", "AUS": "off", "EIN": "on", "ALLE": "all", "DATEN": "data",
        "PROGRAMM": "program", "STAND": "version", "NUMMER": "number", "HARDWARE": "hardware", "SOFTWARE": "software",
    ]

    /// English reading of a job name, or nil if no word is known.
    static func english(_ job: String) -> String? {
        let parts = job.uppercased().split(separator: "_").map(String.init)
        var known = 0
        let words = parts.map { part -> String in
            if let t = tokens[part] { known += 1; return t }
            return part.lowercased()
        }
        guard known > 0 else { return nil }
        let text = words.joined(separator: " ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

/// Offline glossary first, then Apple's on-device German -> English translation (iOS 18+).
@MainActor
public final class TranslationStore: ObservableObject {
    @Published public var translations: [String: String] = [:]
    @Published public var pendingVersion = 0
    @Published public var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "translateGerman") }
    }

    private(set) var pending: Set<String> = []
    private var requested: Set<String> = []

    public init() {
        enabled = UserDefaults.standard.object(forKey: "translateGerman") as? Bool ?? true
    }

    /// Cached or glossary English text, if known.
    func english(_ s: String) -> String? {
        guard enabled else { return nil }
        if let g = Glossary.english(s) { return g }
        return translations[s]
    }

    /// Asks for a translation of text that is not known yet.
    func request(_ s: String) {
        guard enabled, Self.worthTranslating(s), Glossary.english(s) == nil,
              translations[s] == nil, !requested.contains(s) else { return }
        requested.insert(s)
        pending.insert(s)
        pendingVersion += 1
    }

    func takePending() -> [String] {
        let p = Array(pending)
        pending.removeAll()
        return p
    }

    func store(_ source: String, _ target: String) {
        translations[source] = target
    }

    func giveUp(_ source: String) { requested.remove(source) }

    /// Skip numbers, codes (UPPER_CASE_WITH_UNDERSCORES), hex and very short strings.
    static func worthTranslating(_ s: String) -> Bool {
        let letters = s.filter { $0.isLetter }
        guard letters.count >= 4 else { return false }
        if s.contains("_") && s == s.uppercased() { return false }
        if s.allSatisfy({ $0.isHexDigit || $0 == " " || $0 == "-" || $0 == "." }) { return false }
        return true
    }
}

#if canImport(Translation)
@available(iOS 18.0, macOS 15.0, *)
struct TranslationHost: View {
    @ObservedObject var store: TranslationStore
    @State private var configuration: TranslationSession.Configuration?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .translationTask(configuration) { session in
                let batch = await store.takePending()
                guard !batch.isEmpty else { return }
                let requests = batch.map { TranslationSession.Request(sourceText: $0, clientIdentifier: $0) }
                do {
                    for try await response in session.translate(batch: requests) {
                        if let id = response.clientIdentifier {
                            await store.store(id, response.targetText)
                        }
                    }
                } catch {
                    for s in batch { await store.giveUp(s) }
                }
            }
            .onChange(of: store.pendingVersion) { _, _ in
                if configuration == nil {
                    configuration = TranslationSession.Configuration(
                        source: Locale.Language(identifier: "de"),
                        target: Locale.Language(identifier: "en"))
                } else {
                    configuration?.invalidate()
                }
            }
    }
}
#endif

/// Shows German text with an English translation (when available) and the original beneath it.
struct TText: View {
    @EnvironmentObject var translator: TranslationStore
    let text: String
    var italic = false
    init(_ text: String, italic: Bool = false) { self.text = text; self.italic = italic }

    var body: some View {
        let en = translator.english(text)
        VStack(alignment: .leading, spacing: 1) {
            Text(en ?? text).italic(italic)
            if let en, en.caseInsensitiveCompare(text) != .orderedSame {
                Text(text).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .onAppear { translator.request(text) }
    }
}
