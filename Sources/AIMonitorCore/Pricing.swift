import Foundation

/// Per-million-token rates for a model.
public struct ModelRate: Sendable, Equatable {
    public let inputPerMTok: Decimal
    public let outputPerMTok: Decimal
    /// Intro rate and the date it stops applying, when a model has one.
    public let introInputPerMTok: Decimal?
    public let introOutputPerMTok: Decimal?
    public let introEndsBefore: Date?

    public init(
        input: Decimal,
        output: Decimal,
        introInput: Decimal? = nil,
        introOutput: Decimal? = nil,
        introEndsBefore: Date? = nil
    ) {
        self.inputPerMTok = input
        self.outputPerMTok = output
        self.introInputPerMTok = introInput
        self.introOutputPerMTok = introOutput
        self.introEndsBefore = introEndsBefore
    }

    func rates(asOf date: Date) -> (input: Decimal, output: Decimal) {
        if let end = introEndsBefore, let i = introInputPerMTok, let o = introOutputPerMTok, date < end {
            return (i, o)
        }
        return (inputPerMTok, outputPerMTok)
    }
}

/// Anthropic list pricing.
///
/// Only rates that could be verified are present. A model absent from this
/// table produces **no cost figure at all** — it is recorded in
/// `ScanStats.unpricedModels` and degrades cost confidence. A guessed price is
/// worse than a missing one, because a guess still adds up.
public struct PricingTable: Sendable {
    /// Cache reads bill at roughly a tenth of the input rate.
    public static let cacheReadMultiplier = Decimal(string: "0.1")!
    /// A 5-minute-TTL cache write bills at 1.25x the input rate.
    public static let cacheWrite5mMultiplier = Decimal(string: "1.25")!
    /// A 1-hour-TTL cache write bills at 2x the input rate — not 1.25x.
    ///
    /// This matters more than it looks: in the live Claude Code logs on this
    /// machine, essentially every cache write is `ephemeral_1h`. Applying a flat
    /// 1.25x to an undifferentiated `cache_creation_input_tokens` field would
    /// under-bill those writes by 37.5%.
    public static let cacheWrite1hMultiplier = Decimal(string: "2.0")!

    private static func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)!
    }

    /// Standard rates, keyed by exact model id.
    public static let anthropic: [String: ModelRate] = [
        "claude-fable-5": ModelRate(input: 10, output: 50),
        "claude-mythos-5": ModelRate(input: 10, output: 50),
        "claude-opus-5": ModelRate(input: 5, output: 25),
        "claude-opus-4-8": ModelRate(input: 5, output: 25),
        "claude-opus-4-7": ModelRate(input: 5, output: 25),
        "claude-opus-4-6": ModelRate(input: 5, output: 25),
        "claude-sonnet-5": ModelRate(
            input: 3, output: 15,
            introInput: 2, introOutput: 10,
            introEndsBefore: day(2026, 9, 1)
        ),
        "claude-sonnet-4-6": ModelRate(input: 3, output: 15),
        "claude-haiku-4-5": ModelRate(input: 1, output: 5),
    ]

    /// Fast mode runs the same model at premium rates. The Claude Code logs
    /// carry `usage.speed`, so this is detectable rather than assumed.
    public static let anthropicFastMode: [String: ModelRate] = [
        "claude-opus-5": ModelRate(input: 10, output: 50),
        "claude-opus-4-8": ModelRate(input: 10, output: 50),
    ]

    /// Resolves a rate for a model id.
    ///
    /// Dated snapshot ids (`claude-haiku-4-5-20251001`) resolve to their base
    /// alias by longest-prefix match. Synthetic and unknown ids return nil.
    public static func rate(forModel model: String, speed: String?) -> ModelRate? {
        if model.hasPrefix("<") { return nil }  // e.g. "<synthetic>" — locally generated, not billed

        let normalized = model.hasPrefix("anthropic.")
            ? String(model.dropFirst("anthropic.".count))
            : model

        if speed == "fast", let fast = anthropicFastMode[normalized] { return fast }
        if let exact = anthropic[normalized] { return exact }

        // Dated snapshot: fall back to the longest matching alias.
        let candidates = anthropic.keys.filter { normalized.hasPrefix($0) }
        if let best = candidates.max(by: { $0.count < $1.count }) {
            if speed == "fast", let fast = anthropicFastMode[best] { return fast }
            return anthropic[best]
        }
        return nil
    }

    /// Costs a breakdown at list price. Returns nil for an unpriced model.
    public static func cost(
        of tokens: TokenBreakdown,
        model: String,
        speed: String?,
        asOf date: Date
    ) -> Decimal? {
        guard let rate = rate(forModel: model, speed: speed) else { return nil }
        let (inputRate, outputRate) = rate.rates(asOf: date)
        let perToken = { (count: Int, rate: Decimal) -> Decimal in
            Decimal(count) / Decimal(1_000_000) * rate
        }
        return perToken(tokens.uncachedInput, inputRate)
            + perToken(tokens.cachedInput, inputRate * cacheReadMultiplier)
            + perToken(tokens.cacheWrite5m, inputRate * cacheWrite5mMultiplier)
            + perToken(tokens.cacheWrite1h, inputRate * cacheWrite1hMultiplier)
            // TTL-less writes are costed at the 5m rate because 5m is the
            // default TTL. This is the one assumption in the cost path, and a
            // non-zero `cacheWriteUnspecified` makes the report say so.
            + perToken(tokens.cacheWriteUnspecified, inputRate * cacheWrite5mMultiplier)
            + perToken(tokens.output, outputRate)
    }
}
