import Foundation

/// Generates random workspace names from an embedded word list.
/// Three hyphenated words give 8M+ combinations without network requests.
enum WordList {
    /// ~200 common, easy-to-type, inoffensive nouns.
    private static let words: [String] = [
        "acorn", "amber", "anchor", "apple", "arch", "arrow", "aspen", "atlas",
        "badge", "barn", "basin", "beach", "beam", "bench", "birch", "blade",
        "bloom", "bluff", "board", "bolt", "bone", "bower", "brass", "brick",
        "brook", "brush", "cairn", "canal", "cape", "cargo", "cedar", "chalk",
        "chart", "chief", "chord", "cider", "cliff", "clock", "cloud", "coast",
        "cobra", "coral", "crane", "creek", "crest", "cross", "crown", "curve",
        "daisy", "delta", "depot", "dew", "dock", "dome", "drift", "drum",
        "dune", "eagle", "ember", "fable", "farm", "fence", "ferry", "field",
        "flame", "flask", "flint", "flora", "forge", "frost", "gale", "gate",
        "gem", "glade", "glass", "globe", "grain", "grape", "grove", "guide",
        "gust", "haven", "hawk", "hearth", "hedge", "helm", "herb", "heron",
        "hill", "hive", "holly", "hood", "horn", "hull", "iris", "iron",
        "ivory", "jade", "jewel", "junction", "keel", "kernel", "kettle", "knoll",
        "lake", "lance", "larch", "latch", "laurel", "lawn", "ledge", "light",
        "lily", "linen", "lodge", "lotus", "lunar", "maple", "marsh", "mason",
        "mast", "meadow", "mesa", "mill", "mint", "mirth", "moon", "moss",
        "mound", "nexus", "north", "novel", "oak", "oasis", "ocean", "olive",
        "onyx", "orbit", "otter", "palm", "panel", "path", "peak", "pearl",
        "petal", "pier", "pine", "plank", "plaza", "plume", "pond", "poplar",
        "port", "prism", "pulse", "quail", "quartz", "rain", "range", "raven",
        "reef", "ridge", "river", "robin", "root", "rover", "ruby", "rush",
        "sage", "sail", "scale", "scout", "seal", "shade", "shore", "sierra",
        "silk", "slate", "slope", "solar", "spark", "spire", "spray", "spruce",
        "staff", "stamp", "steel", "stone", "storm", "straw", "surge", "swift",
        "thorn", "tide", "tiger", "torch", "tower", "trail", "tulip", "tundra",
        "vale", "vault", "verse", "vigor", "vine", "vista", "wagon", "walnut",
        "wave", "wheat", "willow", "wind", "wren", "yarn", "zenith"
    ]

    /// Generate a random workspace name from three hyphenated words.
    static func randomName() -> String {
        let selected = (0..<3).map { _ in words.randomElement()! }
        return selected.joined(separator: "-")
    }
}
