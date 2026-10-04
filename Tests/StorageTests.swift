import Foundation
import Testing
@testable import Voce

// Preferenze tipizzate: un solo posto per nome e valore predefinito.

@Suite struct PrefsTests {
    @Test func defaultUntilSetThenStoredValue() {
        let pref = Pref("test.\(UUID().uuidString)", 600)
        defer { UserDefaults.standard.removeObject(forKey: pref.key) }
        #expect(pref.value == 600)
        pref.value = 900
        #expect(pref.value == 900)
        #expect(UserDefaults.standard.integer(forKey: pref.key) == 900)
    }

    @Test func unreadableValueFallsBackToDefault() {
        let pref = Pref("test.\(UUID().uuidString)", true)
        defer { UserDefaults.standard.removeObject(forKey: pref.key) }
        UserDefaults.standard.set("non un booleano", forKey: pref.key)
        #expect(pref.value == true)
    }

    @Test func localServices() {
        #expect(Prefs.isLocal("http://localhost:1234"))
        #expect(Prefs.isLocal("http://127.0.0.1:11434/v1"))
        #expect(!Prefs.isLocal("https://api.groq.com/openai"))
    }
}
