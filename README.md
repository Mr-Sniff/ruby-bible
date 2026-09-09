# ruby-bible

> **Vibe-coded.** This project was written with heavy AI assistance
> ("vibe coding"). It works and is kept intentionally dependency-free, but
> treat it as a fun experiment rather than production-hardened code — the
> original author is the LLM, and nobody has fully reviewed it.

A yazi-style terminal UI for browsing **Ruby itself**: every loaded class,
module and singleton object, their methods, the *actual source code* of
Ruby-defined methods, and the official documentation, usage notes and
examples pulled straight from `ri` (RDoc's documentation database).

Nothing in the content is written by hand — descriptions, examples and
use cases come from the installed Ruby/gem documentation; method lists,
signatures, arity, visibility and source lines are read live from the
running interpreter.

## Layout

```
◆ ruby-bible  Module #==                                         docs: core + gems
┌─ Objects ──────────────┐┌─ Methods ────────────────┐┌─ Preview  Module#== ──────────┐
│ ▾ Core (15)            ││ ── instance (60) ──      ││ Module#==(arg0)               │
│   [C] Object           ││   <                      ││ owner: Module · public        │
│   [C] BasicObject      ││   ancestors              ││ defined: C builtin            │
│   [M] Kernel           ││   attr_accessor          ││ ── docs (ri) ──────────────── │
│ ▸ Collections (9)      ││   class_eval             ││ (official description, usage, │
│ ...                    ││   ...                    ││  examples from ri)            │
│                        ││ ── singleton (N) ──      ││ ── source ─────────────────── │
│                        ││   . allocate             ││ extracted Ruby source, or a   │
│                        ││   ...                    ││ "implemented in C" note       │
└────────────────────────┘└──────────────────────────┘└───────────────────────────────┘
j/k move · ↵/l open · / filter · ? help · q quit
```

- **Objects** — curated topic groups (Core, Collections, Strings & patterns,
  Numbers & math, IO & files, Networking, Concurrency, Errors, …) plus an
  *All loaded* index of every top-level class/module reachable from
  `Object.constants`.
- **Methods** — the selected target's own instance and singleton methods.
  Press `a` to regroup by defining ancestor (shows where inherited methods
  come from).
- **Preview** — signature, owner, visibility, arity, source location, full
  `ri` documentation (description, usage, examples), and extracted source
  code with light syntax highlighting.

## Keybindings

| Key              | Action                                       |
|------------------|----------------------------------------------|
| `j` `k` / arrows | move cursor (scroll in preview)               |
| `l` / `Enter`    | expand group · focus preview                  |
| `h`              | collapse / move focus left                    |
| `Tab` / `1 2 3`  | cycle / jump between panes                    |
| `/`              | filter current pane (Enter keeps, Esc clears) |
| `a`              | toggle inherited methods                      |
| `d` / `s`        | jump to docs / source section in preview      |
| `g` / `G`        | top / end                                     |
| `Ctrl-D/U`       | half-page scroll in preview                   |
| `?`              | keybinding help                               |
| `q`              | quit                                          |

## Requirements

- Ruby ≥ 3.1 (uses `io/console`, `RubyVM::AbstractSyntaxTree` fallbacks).
- Runs on **Linux and Windows** (Windows 10+ in Windows Terminal or any
  VT-capable console). On Windows it auto-enables VT output and UTF-8 and
  falls back to a threaded input reader, so the Unix fast path is unchanged.
- `ri` with a documentation database. Gem docs are installed by default;
  **core docs** (String, Array, Module, …) are a separate package on some
  distros:
  - Arch/CachyOS: `sudo pacman -S ruby-docs`
  - Debian/Ubuntu: `sudo apt install ruby3.X-doc` (or build Ruby with `make install-doc`)
  - or, without root: `dev/fetch-core-docs.sh` — downloads the Arch package
    (~670 MB) and extracts only the ri database to
    `~/.local/share/ruby-bible/ri`, where the app finds it automatically.
- The status line in the top-right corner tells you whether core docs are
  available and shows an install hint if not. The app still works without
  them (gem docs, method lists and source all keep working).

## Running

```sh
bin/ruby-bible            # Linux / macOS
ruby bin\ruby-bible       # Windows
```

No gems needed — pure Ruby stdlib.

Debug modes:

```sh
bin/ruby-bible --once          # render one frame and exit
bin/ruby-bible --keys=$'/set\n2/add\n3sjq'   # scripted key sequence
```

## Smoke test

```sh
ruby dev/check.rb
```

checks source extraction (normal + endless defs), C-method detection,
signatures, the ri pipeline and preview building.

## Project layout

```
bin/ruby-bible               entry point
lib/ruby_bible.rb            requires
lib/ruby_bible/registry.rb   catalog of classes/modules/singleton objects
lib/ruby_bible/introspect.rb method lists, signatures, source extraction
lib/ruby_bible/docs.rb       in-process RDoc::RI lookups (ri fallback)
lib/ruby_bible/screen.rb     ANSI renderer: boxes, wrapping, panes
lib/ruby_bible/app.rb        state, key handling, async doc loading
```

Documentation lookups use an in-process `RDoc::RI::Driver` (~0–5 ms after a
one-time ~100 ms init) and preload the whole Methods pane in the background
when you switch targets, so descriptions appear instantly while scrolling.
