# notes-el

`notes-el` is a lightweight Markdown note manager for Emacs.

It stores each note as a plain Markdown file with YAML front matter, while
keeping recent access order in a small JSON metadata file. The goal is to keep
your notes transparent and portable, with Emacs providing only a thin layer for
creating, listing, opening, renaming, and searching notes.

## Features

- One note per Markdown file
- YAML front matter for note metadata
- Stable timestamp-based note IDs, independent of titles
- Recently accessed note list
- Automatic `updated` timestamp refresh on save
- Automatic note saving after edits, enabled by default
- Access tracking when note files are opened directly with `find-file`
- Optional note search via `consult-ripgrep`

## Requirements

- Emacs 27.1 or later
- Optional: `consult` for `notes-search`

## Installation

Clone this repository somewhere on your `load-path`:

```sh
git clone https://github.com/noitak/notes-el.git
```

Then add it to your Emacs configuration:

```elisp
(add-to-list 'load-path "/path/to/notes-el")
(require 'notes)
```

If you use `use-package`:

```elisp
(use-package notes
  :load-path "/path/to/notes-el"
  :custom
  (notes-directory "~/notes/"))
```

## Quick Start

By default, notes are stored in `~/notes/`.

To use a different directory, set `notes-directory` explicitly:

```elisp
(setq notes-directory "~/Documents/notes/")
```

Create a note:

```elisp
M-x notes-new
```

Open the note list:

```elisp
M-x notes-list
```

Inside the note list:

| Key | Action |
| --- | --- |
| `RET` | Open the note at point |
| `n` | Create a new note |
| `g` | Refresh the list |
| `r` | Rename the note at point |
| `s` | Search notes with `consult-ripgrep` |
| `q` | Quit the list window |

## Commands

| Command | Description |
| --- | --- |
| `notes-list` | Display notes ordered by recent access |
| `notes-new` | Create a new note |
| `notes-open` | Open a note by title completion |
| `notes-search` | Search notes with `consult-ripgrep` |
| `notes-list-refresh` | Refresh the note list buffer |
| `notes-list-new` | Create a note from the note list |
| `notes-list-rename` | Rename the note at point in the note list |
| `notes-list-open` | Open the note at point in the note list |

## Configuration

### `notes-directory`

Directory where notes are stored.

Default:

```elisp
"~/notes/"
```

Example:

```elisp
(setq notes-directory "~/Documents/notes/")
```

### `notes-access-file-name`

File name used to store access timestamps inside `notes-directory`.

Default:

```elisp
".notes-access.json"
```

### `notes-auto-save`

Whether note buffers should be saved automatically after edits.

Default:

```elisp
t
```

Disable automatic saving:

```elisp
(setq notes-auto-save nil)
```

### `notes-auto-save-idle-delay`

Seconds of idle time before an edited note buffer is saved automatically.

Default:

```elisp
1.0
```

## File Format

Each note is stored as a Markdown file named after its note ID:

```text
~/notes/
  20260521T153012.md
  20260521T160230.md
  .notes-access.json
```

A note looks like this:

```markdown
---
id: 20260521T153012
title: "Example note"
created: 2026-05-21T15:30:12+09:00
updated: 2026-05-21T15:30:12+09:00
tags: []
---

Write your note here.
```

The file name is based on the note ID, not the title, so renaming a note does
not move or rename the Markdown file.

## Access Order

`notes-list` sorts notes by recent access. Access timestamps are stored in
`.notes-access.json` instead of being written into the Markdown files, so simply
opening a note does not modify the note content.

Access time is updated when:

- A note is created with `notes-new`
- A note is opened from `notes-list`
- A note is opened with `notes-open`
- A note file in `notes-directory` is opened directly with `find-file`

## Searching

`notes-search` uses `consult-ripgrep` to search inside `notes-directory`.

Install `consult` if you want to use this command:

```elisp
(use-package consult)
```

## Development

Run the test suite with:

```sh
emacs -Q -batch -L . -l notes-test.el -f ert-run-tests-batch-and-exit
```

## License

See [LICENSE.txt](LICENSE.txt).
