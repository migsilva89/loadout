import Foundation

/// What a skill costs to have installed, and whether it stays inside the limits Anthropic's
/// own `skill-creator` documents.
///
/// The three-level loading model is what makes the two numbers different things:
/// the name and description are *always* in context, once per session, whether or not the
/// skill ever fires; the body only arrives when it triggers; bundled files only when read.
/// A fat description is therefore a permanent tax and a fat body is not, so the app reports
/// them apart rather than adding them up.
public struct Budget: Equatable, Sendable {
    /// Characters of the frontmatter description — the part that is always loaded.
    public var descriptionCharacters: Int
    /// Lines of the body, after the frontmatter.
    public var bodyLines: Int
    /// Words of the body.
    public var bodyWords: Int
    public var bodyCharacters: Int
    public var nameCharacters: Int

    public init(
        descriptionCharacters: Int = 0, bodyLines: Int = 0, bodyWords: Int = 0,
        bodyCharacters: Int = 0, nameCharacters: Int = 0
    ) {
        self.descriptionCharacters = descriptionCharacters
        self.bodyLines = bodyLines
        self.bodyWords = bodyWords
        self.bodyCharacters = bodyCharacters
        self.nameCharacters = nameCharacters
    }

    // MARK: Limits
    //
    // From `skill-creator/SKILL.md` and its `scripts/quick_validate.py`, verbatim:
    //   · metadata (name + description) is always in context, "~100 words"
    //   · the body arrives on trigger and should stay "<5k words"
    //   · "Keep SKILL.md body to the essentials and under 500 lines"
    //   · name at most 64 characters, description at most 1024 (hard, the validator rejects)

    public static let maxNameCharacters = 64
    public static let maxDescriptionCharacters = 1024
    public static let maxBodyLines = 500
    public static let maxBodyWords = 5_000

    /// Roughly four characters per token. There is no tokenizer on the machine, so this is
    /// an estimate and the UI says so rather than implying precision.
    public static func estimatedTokens(characters: Int) -> Int { characters / 4 }

    /// The always-loaded cost: the description, paid in every session of every project.
    public var descriptionTokens: Int { Budget.estimatedTokens(characters: descriptionCharacters) }
    /// The on-trigger cost: the body, paid only when the skill actually fires.
    public var bodyTokens: Int { Budget.estimatedTokens(characters: bodyCharacters) }

    /// Every limit this skill breaks, said the way a person would say it.
    public var breaches: [String] {
        var found: [String] = []
        if nameCharacters > Budget.maxNameCharacters {
            found.append("The name is \(nameCharacters) characters; the limit is \(Budget.maxNameCharacters).")
        }
        if descriptionCharacters > Budget.maxDescriptionCharacters {
            found.append("The description is \(descriptionCharacters) characters; the limit is \(Budget.maxDescriptionCharacters).")
        }
        if bodyLines > Budget.maxBodyLines {
            found.append("The body is \(bodyLines) lines; Anthropic's guidance is under \(Budget.maxBodyLines). Move detail into reference files.")
        }
        if bodyWords > Budget.maxBodyWords {
            found.append("The body is \(bodyWords) words; the guidance is under \(Budget.maxBodyWords).")
        }
        return found
    }

    public var isOverBudget: Bool { !breaches.isEmpty }

    /// Measures a `SKILL.md` as it sits on disk.
    public static func measure(document: String) -> Budget {
        let front = Frontmatter.parse(document)
        let body = front.body
        return Budget(
            descriptionCharacters: (front.description ?? "").count,
            bodyLines: body.isEmpty ? 0 : body.components(separatedBy: "\n").count,
            bodyWords: body.split(whereSeparator: { $0.isWhitespace }).count,
            bodyCharacters: body.count,
            nameCharacters: (front.name ?? "").count
        )
    }
}
