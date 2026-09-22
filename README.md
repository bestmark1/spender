<h1 align="center">
  <img src="site/assets/spender-icon-160.png" width="88" alt=""><br>
  Spender
</h1>

<p align="center">
  Every LLM API bill in one macOS menu&nbsp;bar panel.<br>
  <a href="https://usespender.com">usespender.com</a> · free · open source · MIT
</p>

<p align="center">
  <img src="docs/images/panel-today.png" width="340" alt="The Spender panel: total spend, a bar showing which providers it is made of, and one card per provider with its balance">
</p>

Spender reads your spend straight from OpenAI, Anthropic, DeepSeek, xAI, Kimi,
Qwen and OpenRouter. Keys stay in the macOS Keychain — there is no
Spender account, no backend, and no credential proxy.

It never passes an estimate off as an official figure: every number is labelled
with where it came from, and a metric a provider does not report is left blank
rather than rounded down to zero.

## Install

**[Download Spender.dmg](https://github.com/bestmark1/spender/releases/latest/download/Spender.dmg)**
— the latest release, for macOS 14 or later. Open it and drag Spender to
Applications. The app is signed with a Developer ID and notarized by Apple, so
macOS opens it without a warning. Release notes and checksums are on the
[Releases page](https://github.com/bestmark1/spender/releases).

Spender lives in the menu bar and has no Dock icon. Connect a provider from
**Options → Connections**, and turn on **Options → Settings → Launch at Login**
to keep it there after a restart. Prefer to build it yourself? See
[Build and run](#build-and-run).

## What it does

- Shows today, yesterday, and 30-day spend in a menu bar panel.
- Combines supported USD reports into a provider breakdown and daily trend.
- Displays official balances where a provider exposes them.
- Tracks DeepSeek spend locally from balance decreases and clearly labels it as estimated.
- Shows token and model usage when the provider has an official reporting API.
- Lets you reorder and hide providers without removing saved credentials.
- Refreshes in the background, retains the last good snapshot, and supports launch at login.

## What it looks like

Spender lives in the menu bar and shows the running total next to the clock.
Click it to open the panel above: the total, a bar showing which providers it is
made of, then one card per connection, largest spender first. Everything below is
one click deeper.

<img src="docs/images/connections-key.png" width="560" alt="The OpenRouter card in Connections, with an arrow pointing at the empty key field and the label Paste your key here">

**Connecting a provider.** Open **Options → Connections**, find the provider and
paste its key into the field. Some providers need a key that is not their ordinary
inference key — an admin or management key with read access to billing — and
their card says which one and links to the instructions for creating it. Saved
keys go into the macOS Keychain and are never shown again.

<img src="docs/images/panel-30days.png" width="340" alt="The 30 Days tab: each provider labelled Official, and a daily spend chart with every bar split by provider">

**30 Days.** The same total over a month, with each provider labelled `Official`
or `Estimated` so it is clear which figures came from a billing API and which
Spender derived itself. Below it, spend per day, each bar split into the
providers' colours.

<img src="docs/images/panel-deepseek-expanded.png" width="340" alt="An expanded DeepSeek card: an official remaining balance above an estimated period spend, with links to the provider console">

**A card opened up.** DeepSeek publishes no cost history, so Spender derives the
figure from saved balance decreases — and says so on the card, next to the
balance the provider *does* report. Each card also links to that provider's own
billing, dashboard and status pages.

## Supported providers

| Provider | Connection | Metrics in Spender |
| --- | --- | --- |
| OpenAI | Organization Admin API key | Official cost, tokens, and models; remaining balance you enter once (see below) |
| Anthropic | Console Admin API key | Official cost, tokens, and models; remaining balance you enter once (see below) |
| DeepSeek | Standard API key | Official balance; estimated daily spend from saved balance decreases |
| Kimi | Standard API key and matching API host | Official balance |
| Qwen / Alibaba Cloud | Model Studio API key; optional read-only BSS AccessKey credentials | Key validation; official Alibaba Cloud balance and Qwen billing when BSS is configured |
| xAI / Grok | Team-scoped Management API key | Official prepaid balance, usage, and model breakdown |
| OpenRouter | Management API key | Official remaining credits |

### OpenAI and Anthropic balances

OpenAI and Anthropic report what you spent, but their APIs do not return the
credit you have left. So on those two cards you enter it once: **Add Balance**,
then type the amount shown on the provider's Billing page. From then on Spender
subtracts every new official cost report from it, and the card shows both the
remaining balance and what was spent since you entered it.

The result is a calculation, not a figure the provider reported. Top-ups,
refunds and credits it cannot see make it drift, so when it no longer matches
Billing, use **Recalibrate** and enter the current amount again. Anthropic costs
marked partial are not subtracted (see below). DeepSeek, Kimi, xAI,
OpenRouter and Qwen (with BSS credentials) do report their balance, and there it
comes straight from the provider.

### Why some providers are not here

Spender shows only money that a provider itself reports through a documented
API. These providers do not offer that to an ordinary account yet:

| Provider | Why it is missing |
| --- | --- |
| Gemini | An ordinary API key can call the models but cannot read what the account has spent. |
| Perplexity | The same: the API key works for requests, not for billing. |
| Mistral AI | Reading spend needs an Admin API key. Mistral issues those only to Enterprise accounts, through its account team, and the Admin API is still a preview. |
| OpenCode Zen | OpenCode documents only the endpoints for calling models. There is no public way to read the balance or what was spent. |
| Z.ai | You can pay per call or buy usage bundles, but there is no documented API for reading the balance. |

Some apps work around this by calling a provider's internal, undocumented
endpoints. Spender does not: such an endpoint can change or disappear without
notice, and a wrong number is worse than no number. If any of these providers
publishes a supported way to read spend, it can be added.

### Cost reports and token-report failures

A failed or incomplete token report no longer discards a received OpenAI or Anthropic cost report. Missing token totals are omitted, not displayed as zero. OpenAI's complete cost report remains eligible for totals and balance deductions; token-report rate limits still delay retries.

Anthropic remains conservative: when usage scope cannot be checked, or Priority Tier usage is detected, its received costs are retained but marked partial and excluded from automatic balance deductions. The Cost API does not include Priority Tier charges. See [Anthropic's documented scope](https://platform.claude.com/docs/en/manage-claude/usage-cost-api).

### DeepSeek accuracy

DeepSeek's public API returns the current balance but not historical cost buckets. Spender therefore compares consecutive saved balance observations:

- a decrease is saved for the full interval between the two observations;
- Today, Yesterday, and the daily chart include it only when that entire interval fits inside one UTC day;
- 30 Days includes multi-day intervals only when they fit entirely within the selected window; missing observations are not treated as complete history;
- an increase is treated as a top-up and is not counted as negative spend;
- the estimate starts after Spender has saved its first balance observation;
- usage between widely separated observations, grant expiry, or an intervening top-up can make the estimate differ from DeepSeek's Usage export.

Existing daily estimates from older versions are retained, but cannot be redated without their original observation timestamps. These historical estimates are not retroactively corrected.

For authoritative history, use the CSV export on the DeepSeek Usage page.

## Privacy and security

- API keys and administrative secrets are stored in macOS Keychain.
- Provider requests are restricted to declared HTTPS origins.
- Cached snapshots and preferences remain in the user's local Application Support and UserDefaults data.
- The repository contains no telemetry backend and no shared credential service.

Use the narrowest read-only administrative credential each provider supports. Do not reuse inference keys outside their intended provider.

## Requirements

- macOS 14 or later
- Xcode with the macOS SDK
- A personal Apple Development team selected under **Signing & Capabilities** for a signed local install

## Build and run

1. Clone the repository:

   ```bash
   git clone https://github.com/bestmark1/spender.git
   cd spender
   ```

2. Open `LLMSpendMonitor.xcodeproj` in Xcode.
3. Select the **LLMSpendMonitor** scheme and **My Mac** destination.
4. Choose your Development Team in **Signing & Capabilities**.
5. Press **Run**.

To build and install a signed Release copy in `/Applications/Spender.app`:

```bash
./scripts/install-local.zsh
```

The installer builds from the current checkout, replaces only `/Applications/Spender.app`, verifies its code signature, and launches it. Enable **Options → Settings → Launch at Login** if desired.

### Release builds

`./scripts/release.zsh` produces the published DMG: it archives the Release
build, signs it with a Developer ID, has Apple notarize the app and the DMG,
staples both and checks them with Gatekeeper. It needs the maintainer's
Developer ID certificate and stored notarization credentials, and it only
writes to `.build/release/`; publishing the release is a separate step.

## Tests

Run the unit test suite from the command line:

```bash
xcodebuild test \
  -project LLMSpendMonitor.xcodeproj \
  -scheme LLMSpendMonitor \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
```

UI tests require macOS Accessibility permission for the Xcode test runner.

## Project structure

```text
LLMSpendMonitor/
├── App/              app and menu bar lifecycle
├── Domain/           money, metrics, and provider snapshots
├── Features/         dashboard, connections, and customization state
├── Infrastructure/   networking, Keychain, and local persistence
├── Providers/        provider-specific API clients
├── Services/         refresh, aggregation, and notifications
└── UI/               SwiftUI menu bar interface
```

Provider API notes and contract validation material live in [`docs/research`](docs/research).

---

<p align="center">
  Made by <a href="https://github.com/bestmark1">bestmark1</a> · <a href="https://x.com/thesignalnow">X</a>
</p>
