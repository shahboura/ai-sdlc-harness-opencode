# Cost Configuration
<!-- Written by /init-workspace — user-supplied, never bundled. Per ADR-010. -->
<!-- Edit this file to enable $ cost estimates in /dev-workflow report.      -->
<!--                                                                          -->
<!-- Provider pricing pages:                                                  -->
<!--   Anthropic Claude:  https://www.anthropic.com/pricing                  -->
<!--   Azure OpenAI:      https://azure.microsoft.com/pricing/details/       -->
<!--                        cognitive-services/openai-service/               -->
<!--   OpenAI:            https://openai.com/pricing                         -->
<!--   Google Vertex AI:  https://cloud.google.com/vertex-ai/pricing         -->
<!--                                                                          -->
<!-- Leave rate cells empty → report emits "cost: n/a (configure             -->
<!-- cost-config.md)" instead of $0.00 (null ≠ zero per CC-02.4.2).         -->
<!-- Fill in your team's deployed model(s) and ignore the rest.              -->

> **Owner:** workspace (per-team)
> **Written by:** `/init-workspace` — edit rates after generation; do not delete.
> **Consumer:** `commands/report.md` (/dev-workflow report)
> **Authority:** ADR-010 (user-supplied cost config, never bundled)

---

## Settings

currency: USD

---

## Per-Model Rates (USD per 1M tokens)

| model | input_per_1m | output_per_1m | cache_read_per_1m | cache_write_per_1m |
|---|---|---|---|---|
| claude-opus-4-5 | | | | |
| claude-sonnet-4-5 | | | | |
| claude-haiku-4-5 | | | | |
| claude-opus-4 | | | | |
| claude-sonnet-4 | | | | |
| claude-haiku-4 | | | | |

<!-- Example filled row (rates illustrative only — check provider page):       -->
<!-- | claude-sonnet-4-5 | 3.00 | 15.00 | 0.30 | 3.75 |                       -->

---

## Notes

- **`input_per_1m`** — cost per 1 million input (prompt) tokens
- **`output_per_1m`** — cost per 1 million output (completion) tokens
- **`cache_read_per_1m`** — cost per 1 million cache-read tokens (prompt cache hit)
- **`cache_write_per_1m`** — cost per 1 million cache-write tokens (prompt cache miss)
- Add rows for any model not listed above; the report matches on the exact model string.
- `currency` affects the `$` symbol in report output only; all rates must be in that currency.
