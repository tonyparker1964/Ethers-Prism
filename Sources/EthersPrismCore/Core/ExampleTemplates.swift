import Foundation

/// Editable starting points. Fixed IDs let the app seed them once without duplicating.
extension EditorTemplate {
    public static let examples: [EditorTemplate] = [clearWriting, visualCharacter, learningExplanation]

    private static func dial(_ name: String, _ detail: String, _ low: String, _ high: String, _ value: Double = 50) -> Dial {
        Dial(name: name, detail: detail, lowPole: low, highPole: high, value: value)
    }

    public static let clearWriting = EditorTemplate(
        id: UUID(uuidString: "6F1A2B3C-0001-4E50-9A10-000000000001")!,
        name: "Clear Writing",
        summary: "Announcements, emails and posts that say what they mean.",
        domainID: "text",
        dials: [
            dial("Directness", "How plainly the main point is stated.", "diplomatic and hedged", "blunt and direct", 65),
            dial("Warmth", "Emotional temperature of the voice.", "formal and reserved", "warm and personal"),
            dial("Reading level", "Vocabulary and sentence complexity.", "plain everyday words", "specialist vocabulary", 30),
            dial("Detail", "How much supporting information is included.", "essentials only", "thorough and complete", 40),
            dial("Structure", "How the text is laid out.", "flowing prose", "scannable headings and bullets", 40)
        ],
        constraints: [Constraint(kind: .accuracy, text: "Do not invent facts, names, dates or figures.")],
        builtIn: true)

    public static let visualCharacter = EditorTemplate(
        id: UUID(uuidString: "6F1A2B3C-0002-4E50-9A10-000000000002")!,
        name: "Visual Character Exploration",
        summary: "Find the look of a character by playing with style, light and symbolism.",
        domainID: "image",
        dials: [
            dial("Realism", "How lifelike the rendering is.", "stylized illustration", "photoreal", 40),
            dial("Visual complexity", "Amount of detail and ornament.", "minimal shapes", "intricate detail"),
            dial("Color intensity", "Saturation of the palette.", "muted and soft", "vivid and saturated"),
            dial("Lighting contrast", "How dramatic the light is.", "soft even light", "dramatic chiaroscuro"),
            dial("Symbolic depth", "How much the image carries meaning beyond the literal.", "direct, literal imagery", "layered metaphor and archetypal symbolism"),
            dial("Composition", "How the character sits in the frame.", "calm centered portrait", "dynamic action scene", 30)
        ],
        constraints: [Constraint(kind: .mustAvoid, text: "text, watermarks, logos")],
        builtIn: true)

    public static let learningExplanation = EditorTemplate(
        id: UUID(uuidString: "6F1A2B3C-0003-4E50-9A10-000000000003")!,
        name: "Learning Through Explanation",
        summary: "Explain an idea so it actually lands for the reader.",
        domainID: "text",
        dials: [
            dial("Reading level", "Who the explanation is pitched at.", "complete beginner", "advanced learner", 25),
            dial("Analogy vs precision", "How ideas are conveyed.", "vivid everyday analogies", "precise technical terms", 35),
            dial("Historical context", "How much of the story behind the idea is told.", "none", "rich history of discovery", 30),
            dial("Examples", "How much is shown rather than told.", "one quick example", "several worked examples"),
            dial("Interactivity", "Whether the reader is asked to think along.", "straight explanation", "questions for the reader", 40)
        ],
        constraints: [Constraint(kind: .accuracy, text: "Be factually accurate and say clearly where something is simplified.")],
        builtIn: true)
}
