# 0009 — DeepSeek as an optional AI provider

- **Date:** 2026-10-06
- **Status:** accepted
- **Skills consulted:** claude-api (Claude request shape, pricing table)

## Context

The owner wants the cheapest option for AI wording. DeepSeek (deepseek-chat) costs roughly a tenth of Claude
Haiku per token, according to published price lists in October 2026. Peak's AI layer (decision 0007) talks to
Claude's Messages API.

## Decision

1. `PEAK_AI_PROVIDER` = `claude` | `deepseek` | `none`. Unset means whichever key is present, with Claude first.
2. `DeepSeekClient` implements the same `ClaudeAPI` protocol. It translates Peak's Claude-shaped requests to
   DeepSeek's OpenAI-compatible `/chat/completions` and the replies back, so `AIService` is unchanged: consent,
   daily limits, the monthly cap, the read-only tool loop and the number check all apply equally.
   - The JSON schema goes into the system prompt, with JSON mode on.
   - `tool_use` / `tool_result` map to `tool_calls` / `tool` messages.
   - `length` and `content_filter` raise the same errors as Claude's `max_tokens` and `refusal`.
3. **Consent is per provider.** The consent screen names the provider, and a stored consent records which one it
   was. If the server switches provider, users are asked again before any data goes to the new company.
4. **Costs:** deepseek-chat is in the price list ($0.28 / $0.42 per million tokens). Unknown DeepSeek models are
   charged at a conservative $2 / $8. `PEAK_AI_PRICE_INPUT`/`_OUTPUT` override the price for any model.

## Consequences

- DeepSeek's docs weren't reachable from the build environment. The adapter follows the OpenAI-compatible chat
  format, which DeepSeek documents publicly, and its tests check the translation, but no real DeepSeek call has
  been made. Verify on staging.
- Data sent to DeepSeek is processed by a company based in China, under its privacy policy. The data is the same
  aggregated game stats as with Claude: never player names or IDs.
- Claude-only features (effort, refusal fallbacks, prompt-cache control, thinking) aren't used with DeepSeek.
