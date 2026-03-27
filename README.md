# Parley

A macOS native app for reviewing GitHub PRs that contain markdown documents — KEPs, RFCs, ADRs, and similar proposal formats.

Renders the markdown beautifully, shows inline review comments anchored to specific lines, and supports the full GitHub PR review workflow: read comments, reply, stage draft comments, and submit a batched review.

```
┌─────────────────────────────────────────────────────────┐
│  [PR URL input]              [Refresh] [Submit Review]  │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  # User Identifier Delegated Grant Access               │
│  Author: Benjamin Boudreau                              │
│                                                         │
│  Allowing Application to retrieve the delegated...      │
│  ┌─ 3 comments ───────────────────────────────┐         │
│  │ @TroyBarnes: What's the Greendale ID?        │         │
│  │ @AbedNadir: Yes, the student API ID.        │         │
│  │ [Reply...]                                  │         │
│  └─────────────────────────────────────────────┘         │
│                                                         │
├─────────────────────────────────────────────────────────┤
│  8 comments · 2 drafts · MERGED                         │
└─────────────────────────────────────────────────────────┘
```

## Requirements

- macOS 14 (Sonoma) or later
- [GitHub CLI](https://cli.github.com/) (`gh`) installed and authenticated
- Swift 5.9+ toolchain (via [swiftly](https://swiftlang.github.io/swiftly/) or Xcode)

## Install

### Homebrew (recommended)

```bash
brew install jelmersnoeck/tap/parley
```

### From source

```bash
git clone https://github.com/jelmersnoeck/parley.git
cd parley
just install
```

This builds a release binary and copies it to `/usr/local/bin/parley`.

### Build only

If you have [just](https://just.systems/) installed:

```bash
just build          # debug build
just release        # optimized release build
just app            # create Parley.app bundle in build/
```

Or directly with Swift:

```bash
swift build                  # if you have Xcode installed
swiftly run swift build      # if using swiftly toolchain
```

## Usage

Launch the app:

```bash
just run            # debug
just run-release    # release
```

Or open the `.app` bundle:

```bash
just app
open build/Parley.app
```

Then paste a GitHub PR URL in the top bar and hit Enter:

```
https://github.com/jelmersnoeck/keps/pull/6
```

### Keyboard shortcuts

| Key | Action |
|-----|--------|
| `Enter` (in URL field) | Load PR |
| `Cmd+R` | Refresh |
| `Cmd+Opt+I` | Toggle inspector panel |

### Review workflow

1. **Read** — markdown renders with full GFM support, syntax highlighting, and frontmatter
2. **Browse comments** — click the orange comment indicators to expand inline threads
3. **Reply** — type in the reply box within any expanded thread (posted immediately)
4. **Stage new comments** — hover over a line, click `+`, type your comment, click "Stage"
5. **Review** — open the inspector panel to see all your staged drafts and write a review summary
6. **Submit** — click "Submit Review" and choose Comment, Approve, or Request Changes

All staged comments are batched into a single GitHub review submission.

## Authentication

Parley piggybacks on `gh` CLI authentication. Make sure you're logged in:

```bash
gh auth status       # check
gh auth login        # log in if needed
```

No tokens, no OAuth flows, no config files. If `gh` is authed, Parley is authed.

## Development

```bash
just test                     # run all tests
just test-filter PRURLParser  # run specific suite
just clean                    # clean build artifacts
just lint                     # (placeholder, no linter configured yet)
```

### Project structure

```
Sources/Parley/
├── App/           — SwiftUI app entry point and main content view
├── GitHub/        — API client, data models, URL parser
├── ViewModel/     — @Observable state management
├── Views/         — toolbar, inspector panel, status bar
├── WebView/       — WKWebView wrapper and JS bridge
└── Resources/     — HTML template, CSS, JS (marked.js, highlight.js, DOMPurify)
```

### Architecture

SwiftUI shell wrapping a WKWebView. Markdown is rendered client-side via `marked.js` with `highlight.js` for syntax highlighting. The JS layer communicates with Swift through `WKScriptMessageHandler` — comment actions flow from JS to the view model, and content updates flow from the view model back to JS via `evaluateJavaScript`.

All user-generated content is sanitized with DOMPurify before DOM insertion.

## License

MIT
