# indium.yazi

Preview archives in [yazi](https://github.com/sxyazi/yazi) with
[INDIUM](https://github.com/sudo-megas/INDIUM).

yazi's built-in archive previewer runs `7zz` or `7z` and shows a name and a size. This one runs
`indium`, which reads the container itself, and shows what INDIUM knows about it:

```
?rw-r--r-- 644           21            -  LZMA         2024-01-02 03:04:05 UTC alpha.txt
?rw-r--r-- 644           20            -  LZMA         2024-01-02 03:04:05 UTC beta.txt
?rw-r--r-- 644           21            -  LZMA         2024-01-02 03:04:05 UTC sub/gamma.txt
?rwxr-xr-x 755            -            -  —            2024-01-02 03:04:05 UTC sub

4 entries, 3 files, 1 directory, 62 B
```

Mode, octal mode, size, packed size, method, encryption, timestamp, path, and a total — with `-`
where a packed size genuinely is not knowable and `—` where a directory has no coder.

It also works where the built-in cannot. INDIUM links its decompressors in and shells out to
nothing, so an archive previews on a machine with no 7-Zip installed — where yazi's built-in
prints *"Failed to start either `7zz` or `7z`."* and stops.

## Requirements

**Linux only.** INDIUM is a Linux program — it is built against libarchive and its window is a
Wayland window — so a previewer that runs it is Linux-only too. The listing itself is the terminal
half of INDIUM and opens no window, so it works over SSH and in a bare TTY; it just needs to be a
Linux one. `setsid`, below, is from util-linux and narrows it the same way.

- **yazi 26.5.6 or newer** — that is the API version at the top of `main.lua`
- **`indium` on your `PATH`** — [INDIUM](https://github.com/sudo-megas/INDIUM) v1.2.0 or newer.
  Without it the pane says so, once, instead of previewing.
- **`setsid`**, from util-linux, which you almost certainly already have. Everything still
  previews without it, but an archive with an encrypted header will hang the pane — see
  [below](#refusals-are-shown-not-swallowed) for why.

## Install

```sh
ya pkg add sudo-megas/indium.yazi
```

Then tell yazi to use it, in `~/.config/yazi/yazi.toml`:

```toml
[[plugin.prepend_previewers]]
mime = "application/{zip,7z*,tar,gzip,xz,zstd,bzip*,lzip,cpio,iso9660-image}"
run  = "indium"
```

That list is INDIUM's own — the same formats `org.indium.desktop` registers, so the plugin
previews exactly what INDIUM opens. **`rar` is absent on purpose**: INDIUM does not read RAR, so
hovering one should keep falling through to yazi's built-in previewer, which does.

Note the missing `x-` prefixes. A `.7z` really is `application/x-7z-compressed`, but yazi strips
that prefix before matching a rule, and its own built-in rules are written the same way. Spelling
the MIME types out in full here matches nothing at all, silently — the pane just keeps showing
the built-in previewer's output, which is an easy thing to mistake for the plugin not loading.

To update, and to keep the pinned revision in your `package.toml` honest:

```sh
ya pkg upgrade
```

## What it does

- **`peek`** runs `indium list` over the hovered file and prints the lines into the pane.
- **`seek`** scrolls, so a long archive is a pane you can move through rather than one screenful.
- **Both are lazy.** Reading stops at the screenful being shown, so the first page of an archive
  with a hundred thousand members costs a page.

### It adapts to the width, and parses nothing

`indium list --long` spends 79 columns on the fields before the path, and the path is the *last*
column — so clipping a narrow pane would throw away the one field a listing exists for. The
plugin therefore picks the *command* by the width of the pane:

| Pane | Command | Shows |
| --- | --- | --- |
| **≥ 96 columns** | `indium list --long` | every field, and the totals line |
| **< 96 columns** | `indium list` | paths, undecorated |

and prints whichever it ran unchanged. INDIUM documents `--long` as *"for you to read rather than
for a script to parse"*; a preview pane is a person reading, so nothing here splits those columns
apart, and `--long` stays free to change shape without breaking this plugin.

96 is 79 plus a 17-character budget for the path. It is a judgement, not a law — it lives at the
top of `main.lua` as `LONG_MIN_WIDTH` and is one line to change.

And 79 is the usual case rather than a constant: those columns are minimum widths and none of them
truncates, so a long value pushes everything after it rightward. A cpio's method reads `svr4 with
no crc` and takes the prefix to 87. No single number fits every archive, which is why 96 is a
budget rather than an arithmetic.

### Refusals are shown, not swallowed

INDIUM says why it will not read something, and the pane says what INDIUM said:

| Hovering | The pane says |
| --- | --- |
| an archive whose header is encrypted | `indium: … is encrypted, and there is no terminal to ask for a password on` |
| a file that is not the archive it claims to be | whatever INDIUM said about it, unedited |
| anything, with no `indium` installed | `setsid: failed to execute indium: No such file or directory` |

That last one is `setsid` talking, not this plugin — INDIUM is started through it, so a missing
binary is reported by the program that tried to run it. It names `indium`, which is the part you
need.

A `.rar` is not in the list above because a `.rar` never reaches this plugin: `rar` is absent from
the MIME rule, so yazi keeps handling it with its own previewer.

**It never prompts for a password**, and that takes a little doing. INDIUM asks on `/dev/tty`
deliberately — neither stdin nor stdout, so a prompt can never land inside a pipeline or inside a
file you were extracting. But a preview runs as a child of yazi, and a child of yazi inherits
yazi's terminal, so an archive with an encrypted header would find one and sit there asking. The
pane would hang, and every key you pressed would be eaten by a prompt you cannot see.

So the plugin starts INDIUM through `setsid`, in a session of its own with no controlling terminal
to find. INDIUM documents that case itself: a `setsid` child *"gets a sentence and an exit code
rather than a process that waits forever for a keystroke nobody is there to type"* — and that
sentence is the one worth putting in the pane. Without `setsid` installed the plugin still runs
everything else, and only an encrypted header can still reach for the terminal.

An archive whose *contents* are encrypted but whose header is not lists fine either way: the names
are readable, and `enc` marks the members that are not.

## Licence

GPL-3.0-only, as INDIUM is. See [LICENSE](LICENSE).
