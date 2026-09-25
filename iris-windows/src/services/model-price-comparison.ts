/**
 * The side-by-side under "How Iris answers" — the Windows half of
 * `ModelPriceComparison.swift`.
 *
 * NO PRICE LIVES IN THIS APP. Every number comes from
 * `GET {publik}/api/iris/model-prices` (publik's `lib/iris-model-prices.ts`),
 * which reads publik's own tier prices from the code that bills them and
 * copies Anthropic's and OpenAI's from their published pages with the date
 * they were read. When the route cannot be reached the settings window says so
 * and shows no number at all — a stale price shown as current is exactly the
 * dishonest thing this exists to avoid.
 *
 * One Windows-specific step, `comparisonForThisPc`: this client always asks
 * publik API for `publik-balanced`, and its own-key picker offers different
 * models from the Mac's. So the comparison shown here is the balanced level,
 * with the own-key row repriced for the model the reader actually picked —
 * from the same response's `anthropicListPrices` and its stated assumption,
 * never from a number compiled in.
 */

export interface ComparisonAssumption {
  questionsPerMonth: number;
  inputTokensPerQuestion: number;
  outputTokensPerQuestion: number;
  summary: string;
}

export interface ComparisonOption {
  provider: "publik-api" | "anthropic-key" | "codex";
  label: string;
  model: string;
  servedBy: string | null;
  billing: "per_token" | "subscription";
  inputUsdPerMillion: number | null;
  outputUsdPerMillion: number | null;
  estimatedCostPerQuestionUsd: number | null;
  estimatedMonthlyUsd: number;
  note: string;
  source: string;
}

export interface ComparisonLevel {
  tier: "fast" | "balanced" | "smart";
  options: ComparisonOption[];
}

export interface AnthropicListPrice {
  model: string;
  inputUsdPerMillion: number;
  cacheWriteUsdPerMillion: number;
  cacheReadUsdPerMillion: number;
  outputUsdPerMillion: number;
}

export interface ModelPriceComparison {
  version: 1;
  assumption: ComparisonAssumption;
  caveat: string;
  levels: ComparisonLevel[];
  anthropicListPrices: AnthropicListPrice[];
}

function isFiniteNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value);
}

function isNullableNumber(value: unknown): value is number | null {
  return value === null || isFiniteNumber(value);
}

function isOption(value: unknown): value is ComparisonOption {
  if (!value || typeof value !== "object") return false;
  const option = value as Record<string, unknown>;
  return (
    (option.provider === "publik-api" || option.provider === "anthropic-key" || option.provider === "codex") &&
    typeof option.label === "string" &&
    typeof option.model === "string" &&
    (option.servedBy === null || typeof option.servedBy === "string") &&
    (option.billing === "per_token" || option.billing === "subscription") &&
    isNullableNumber(option.inputUsdPerMillion) &&
    isNullableNumber(option.outputUsdPerMillion) &&
    isNullableNumber(option.estimatedCostPerQuestionUsd) &&
    isFiniteNumber(option.estimatedMonthlyUsd) &&
    typeof option.note === "string" &&
    typeof option.source === "string"
  );
}

/**
 * The route's JSON, checked field by field. Anything unexpected is `null` —
 * the settings window then says prices are unavailable rather than rendering
 * half a comparison.
 */
export function parseModelPriceComparison(body: unknown): ModelPriceComparison | null {
  if (!body || typeof body !== "object") return null;
  const candidate = body as Record<string, unknown>;
  if (candidate.version !== 1) return null;

  const assumption = candidate.assumption as Record<string, unknown> | undefined;
  if (
    !assumption ||
    !isFiniteNumber(assumption.questionsPerMonth) ||
    !isFiniteNumber(assumption.inputTokensPerQuestion) ||
    !isFiniteNumber(assumption.outputTokensPerQuestion) ||
    typeof assumption.summary !== "string"
  ) {
    return null;
  }
  if (typeof candidate.caveat !== "string") return null;

  if (!Array.isArray(candidate.levels) || candidate.levels.length === 0) return null;
  const levels: ComparisonLevel[] = [];
  for (const level of candidate.levels as unknown[]) {
    const record = level as Record<string, unknown> | null;
    if (!record || (record.tier !== "fast" && record.tier !== "balanced" && record.tier !== "smart")) return null;
    if (!Array.isArray(record.options) || !record.options.every(isOption)) return null;
    levels.push({ tier: record.tier, options: record.options as ComparisonOption[] });
  }

  const anthropicListPrices: AnthropicListPrice[] = [];
  if (Array.isArray(candidate.anthropicListPrices)) {
    for (const row of candidate.anthropicListPrices as unknown[]) {
      const price = row as Record<string, unknown> | null;
      if (
        price &&
        typeof price.model === "string" &&
        isFiniteNumber(price.inputUsdPerMillion) &&
        isFiniteNumber(price.cacheWriteUsdPerMillion) &&
        isFiniteNumber(price.cacheReadUsdPerMillion) &&
        isFiniteNumber(price.outputUsdPerMillion)
      ) {
        anthropicListPrices.push(price as unknown as AnthropicListPrice);
      }
    }
  }

  return {
    version: 1,
    assumption: {
      questionsPerMonth: assumption.questionsPerMonth,
      inputTokensPerQuestion: assumption.inputTokensPerQuestion,
      outputTokensPerQuestion: assumption.outputTokensPerQuestion,
      summary: assumption.summary,
    },
    caveat: candidate.caveat,
    levels,
    anthropicListPrices,
  };
}

/**
 * The list price for a model id as the picker stores it, dated snapshot
 * included: "claude-opus-4-1-20250805" is "claude-opus-4-1". Longest match
 * wins, so "claude-opus-4-1" never resolves to a shorter family row.
 */
export function listPriceForModel(comparison: ModelPriceComparison, modelId: string): AnthropicListPrice | null {
  const matches = comparison.anthropicListPrices.filter(
    (row) => modelId === row.model || modelId.startsWith(`${row.model}-`)
  );
  if (matches.length === 0) return null;
  return matches.reduce((longest, row) => (row.model.length > longest.model.length ? row : longest));
}

function roundTo(value: number, places: number): number {
  const factor = 10 ** places;
  return Math.round(value * factor) / factor;
}

/**
 * The comparison as this PC sees it: the balanced level (the tier this client
 * always sends publik API), with the own-key row for the reader's own model.
 * Null when the response has no balanced level. When the reader's model has
 * no listed price, the own-key row is dropped rather than shown with the
 * wrong model's numbers.
 */
export function comparisonForThisPc(
  comparison: ModelPriceComparison,
  readersAnthropicModel: string
): { assumption: ComparisonAssumption; caveat: string; options: ComparisonOption[] } | null {
  const balanced = comparison.levels.find((level) => level.tier === "balanced");
  if (!balanced) return null;

  const options = balanced.options.flatMap((option): ComparisonOption[] => {
    if (option.provider !== "anthropic-key") return [option];
    const price = listPriceForModel(comparison, readersAnthropicModel);
    if (!price) return [];
    const { inputTokensPerQuestion, outputTokensPerQuestion, questionsPerMonth } = comparison.assumption;
    const perQuestion =
      (inputTokensPerQuestion * price.inputUsdPerMillion + outputTokensPerQuestion * price.outputUsdPerMillion) / 1_000_000;
    return [
      {
        ...option,
        model: price.model,
        inputUsdPerMillion: price.inputUsdPerMillion,
        outputUsdPerMillion: price.outputUsdPerMillion,
        estimatedCostPerQuestionUsd: roundTo(perQuestion, 4),
        estimatedMonthlyUsd: roundTo(perQuestion * questionsPerMonth, 2),
      },
    ];
  });

  return { assumption: comparison.assumption, caveat: comparison.caveat, options };
}
