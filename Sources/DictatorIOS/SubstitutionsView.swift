import SwiftUI

/// Built-in deterministic substitutions, pushed from Settings.
/// Each toggle gates one family of patterns inside `SpokenCues` —
/// the punctuation cues ("comma", "new paragraph"), number/arithmetic
/// resolution, clock-time digitisation, currency-symbol mapping, and
/// emoji-by-name lookup. The vocab editor (user's custom replacements)
/// lives in a separate `VocabularyView` because the management story
/// is completely different — these are five known toggles, that one
/// is an editable list.
struct SubstitutionsView: View {
    @AppStorage(DictatorIOSSettings.cuePunctuationKey) private var punctuationEnabled = true
    @AppStorage(DictatorIOSSettings.cueNumbersKey) private var numbersEnabled = true
    @AppStorage(DictatorIOSSettings.cueTimesKey) private var timesEnabled = true
    @AppStorage(DictatorIOSSettings.cueCurrencyKey) private var currencyEnabled = true
    @AppStorage(DictatorIOSSettings.cueEmojisKey) private var emojisEnabled = true

    var body: some View {
        List {
            Section {
                Toggle("Punctuation cues", isOn: $punctuationEnabled)
                Toggle("Numbers & arithmetic", isOn: $numbersEnabled)
                Toggle("Clock times", isOn: $timesEnabled)
                Toggle("Currency", isOn: $currencyEnabled)
                Toggle("Emoji names", isOn: $emojisEnabled)
            } footer: {
                Text("Punctuation: \"comma\", \"new paragraph\", \"open quote\", \"em dash\", etc.\nNumbers: \"five plus three\" → \"5 + 3\", \"twenty-five\" → 25.\nTimes: \"ten thirty PM\" → \"10:30pm\", \"sixteen hundred hours\" → \"1600 hours\".\nCurrency: \"five dollars\" → \"$5\", \"twenty pounds\" → \"£20\".\nEmoji: \"fire emoji\" → 🔥, \"vulcan emoji\" → 🖖. Covers the full Unicode emoji set by name plus hundreds of curated aliases.")
            }
        }
        .navigationTitle("Substitutions")
        .navigationBarTitleDisplayMode(.inline)
    }
}
