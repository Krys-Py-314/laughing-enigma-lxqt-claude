# inst-min-lxqt-rpi5.sh

A minimal-memory LXQt + Openbox desktop for the **Raspberry Pi 5** on top of
**Raspberry Pi OS Lite 64-bit** (Bookworm or Trixie).

```bash
chmod +x inst-min-lxqt-rpi5.sh
./inst-min-lxqt-rpi5.sh
```

Run it as a **normal user with sudo rights**, not as root. Everything is
logged to `~/inst-min-lxqt-rpi5.log`.

## Flags

| Variable | Effect |
|---|---|
| `SKIP_SSH_SWAP=1` | Keep OpenSSH; do not install or switch to dropbear |
| `SKIP_PI_APPS=1`  | Skip Pi-Apps, Min and Geany Dark Mode |
| `SKIP_TRIM=1`     | Do not disable triggerhappy |
| `ASSUME_YES=1`    | Never prompt (unattended run) |

## What gets installed

| Role | Choice | Why |
|---|---|---|
| Session | `lxqt-session` + hand-picked modules | No `lxqt-core` metapackage — it drags in power management, admin tools and an about box |
| WM | Openbox, custom `SquareDark` theme | Flat, 1px, square borders; no rounding, no shadows, no compositor |
| Login | **No display manager** — `startx` from tty1 | A DM is a permanently resident process for one login a day |
| Desktop | `xsetroot -solid #383C48` | No `pcmanfm-qt --desktop` process, no wallpaper decode, no desktop icons |
| Terminal | urxvt | Lightest X11 terminal with real Xft/Nerd Font support and no tabs |
| Browser | vimb | WebKit, keyboard-driven, far lighter than Chromium |
| Files | pcmanfm-qt | Requested; Qt libs are already resident under LXQt |
| Editor | l3afpad | GTK3 Leafpad fork; `leafpad` and `edit` are aliased to it |
| PDF | mupdf | Single binary, ~30 MB RSS, no poppler stack |
| Images | feh | ~10 MB RSS |
| Video | mpv | Reuses the ffmpeg libs already pulled in |
| Recorder | `screenrec` (ffmpeg x11grab wrapper) | Zero resident memory when not recording, unlike any GUI recorder |
| Screenshots | scrot | Makes Openbox's stock `Alt+Print` binding work (~60 KB) |
| Icons | Numix-Circle | Circular app icons, dark Numix folder icons |
| Fonts | Ubuntu + UbuntuMono Nerd Font, size 12 | Applied to fontconfig, Qt/LXQt, GTK2, GTK3 and urxvt |
| SSH | dropbear replaces OpenSSH | ~1 MB resident vs ~8 MB |
| Prompt | oh-my-posh | Requested |
| Dev | gcc, g++, make, libgpiod, raspi-utils-core, git, curl | See GPIO note below |
| Editor (dev) | geany | Installed in step 20 as an ordered prerequisite: "Geany Dark Mode" only recolours an existing Geany and fails without it |

Printing is pinned out entirely (`Pin-Priority: -1` on cups and
`printer-driver-*`), and `APT::Install-Recommends "false"` is set so nothing
pulls in a print stack or other optional weight by accident.

## Deviations from the request — please read

1. **`rasp-utils-core` → `raspi-utils-core`.** The requested spelling does not
   exist. `raspi-utils-core` is the real package (`vcgencmd`, `pinctrl`,
   `vclog`, `vcmailbox`).
2. **`leafpad='l3apad'` → `l3afpad`.** The alias target in the request was a
   typo for the binary that is actually installed.
3. **"Imager app" was read as *image viewer*** (feh), since it was listed
   alongside the PDF and video viewers. If you meant the SD-card flashing tool,
   that is `sudo apt install rpi-imager` — say the word and I will add it.
4. **`Min` contradicts the minimum-memory goal.** It is an Electron browser
   (~250–400 MB RSS with one tab open) — the single heaviest thing in this
   build. It is installed as requested, and the script prints a warning when it
   does. Vimb remains the low-memory browser.
5. **vimb is not in Bookworm.** It entered Debian at Trixie (3.7.0, arm64). On
   Trixie the script installs it with apt; on Bookworm it builds from source
   against whichever WebKitGTK dev package is present (4.1 or 4.0).
6. **fastfetch is not in Bookworm** either. On Trixie it comes from apt; on
   Bookworm the script falls back to the official `fastfetch-linux-aarch64.deb`
   GitHub release.
7. **The dropbear swap is guarded.** It is the last step, it asks first, and it
   only purges `openssh-server` *after* confirming something is listening on
   port 22 — otherwise it re-enables OpenSSH so you cannot be locked out.
   If you are running over SSH, your current session may still drop.
8. **`openssh-client` is kept on purpose.** It is not a daemon, so it costs no
   resident memory, and `ssh`/`scp`/`ssh-keygen` out of the Pi keep working —
   git, rsync and ansible all invoke `/usr/bin/ssh` by name, and `dbclient` is
   not a drop-in replacement. Only the *server* is removed.

## Notes that will bite you later

- **urxvt and high-plane Nerd Font glyphs.** Unless Debian built
  `rxvt-unicode` with `--enable-unicode3`, it cannot render codepoints above
  U+FFFF. The classic Powerline/PUA icons (U+E000–F8FF) that oh-my-posh uses
  are fine; the Material Design range (U+F0001+) will not display. Check with
  `urxvt --help 2>&1 | grep -i unicode3`.
- **libgpiod v1 vs v2.** Bookworm ships 1.6, Trixie ships 2.x, and the C API is
  not source-compatible between them. `~/dev/README-GPIO.md` is written during
  install with the details and build commands.
- **Pi 5 GPIO.** `wiringPi`, `bcm2835` and `pigpio` poke SoC registers directly
  and do **not** work on the Pi 5's RP1 southbridge. Use libgpiod, lgpio, or
  `pinctrl`.
- **How much dropbear actually saves depends on how sshd is started.** Under
  `ssh.service` (Bookworm) a listener is resident from boot at ~5–8 MB, so the
  swap is a real idle win. Under `ssh.socket` (Debian moved to socket
  activation in Trixie) systemd holds the port and no sshd is resident while
  idle, so the idle saving is ~0 and dropbear only wins per connection
  (~5–10 MB per sshd session vs ~1–2 MB). Step 22 detects which model your
  image uses, says so before asking, and prints the measured before/after RSS
  rather than assuming a win.
- **`Geany Dark Mode` needs Geany installed first.** The Pi-Apps app only
  writes theme files into Geany's config — it does not install the editor, and
  fails outright when it is absent. Step 20 installs `geany` before the
  Pi-Apps loop and skips the theme with a clear message if that install did not
  succeed, rather than letting Pi-Apps fail opaquely. Both live inside the
  `SKIP_PI_APPS` guard, so skipping Pi-Apps skips geany too.
- **`dropbear-run` no longer exists.** It was dropped from Debian in dropbear
  2022.83-3; on Trixie the `dropbear` package itself ships the startup files.
  `dropbear-bin` provides `/usr/sbin/dropbear` and *nothing that starts it*, so
  installing only that leaves a machine with the binary present, no init
  script, and no SSH server after the next reboot. Step 22 installs `dropbear`
  plus `dropbear-bin`, falls back to `dropbear-run` for older releases, and
  refuses to touch OpenSSH unless a service or init script actually exists.
- **dropbear's init layout varies by release**, and `systemctl enable` behaves
  differently on each: `dropbear.socket` + `dropbear@.service` (socket
  activated), a plain `dropbear.service`, or just `/etc/init.d/dropbear` wrapped
  by systemd — where `enable` can fail on a generated unit that starts
  perfectly well. Step 22 therefore treats "enabled at boot" and "running now"
  as separate questions and decides success from **which process actually holds
  port 22**, not from any command's exit status. Under socket activation a
  reading of `dropbear resident: 0 kB` is correct rather than a failure.
- **Running now is not the same as running after a reboot.** Where dropbear
  starts from a sysvinit script, systemd may refuse to `enable` it, leaving a
  working machine with no SSH server on the next boot. Step 22 checks this
  separately and prints the `update-rc.d` fix if persistence is missing.
- **avahi-daemon is left running on purpose.** It publishes the Pi as
  `<hostname>.local` over mDNS, so `ssh pi@raspberrypi.local` keeps working.
  Turning it off in the same run that swaps the SSH server (step 22) would mean
  reconnecting to a changed daemon at an address that no longer resolves. The
  only service the script disables is **triggerhappy**, a console hotkey daemon
  that Raspberry Pi OS enables with no triggers configured and that LXQt
  replaces with `lxqt-globalkeys` and Openbox's `rc.xml`.
- **No desktop icons.** That is the direct cost of not running a desktop
  process. If you want them, drop the `Hidden=true` override in
  `~/.config/autostart/` and enable pcmanfm-qt's desktop — it is already
  configured for `#383C48` with no wallpaper.
- **X autostart does not use `exec`.** With console autologin, `exec startx`
  would end the login session whenever X died and the getty would log straight
  back in and retry, looping with no console to fix it from. Keeping the parent
  shell costs ~3 MB and always leaves a usable prompt.

## Verification performed

The script was static-checked and its generated output exercised before
release. Note this ran on an x86 Ubuntu container, **not** on a Pi:

- `bash -n` and `shellcheck` clean at `style` level (excluding SC2024, which
  flags user-owned log redirects under `sudo`, and SC2088, tildes inside
  human-readable messages).
- Unit tests for the package-existence guard: real packages accepted, phantom
  packages rejected and recorded rather than passed to apt, and apt not invoked
  at all when nothing in a group is available. This is what keeps the run free
  of `Unable to locate package` errors.
- `write_block` idempotency: running three times leaves exactly one block and
  preserves pre-existing file content.
- Config generation replayed into a throwaway `$HOME`: `rc.xml` and `menu.xml`
  validated with `xmllint`, `.Xresources` parsed by `xrdb -n` (37 resources),
  `.desktop` files validated with `desktop-file-validate`, `.bashrc` sourced to
  confirm the six aliases (`ll`, `la`, `edit`, `leafpad`, `hh`, `hl`) and the
  PATH entry.
- **Openbox was actually started under Xvfb** with the generated theme, rc.xml
  and menu.xml, and came up with no warnings or errors.

Five real bugs were found and fixed this way: an unquoted `#` in a `.desktop`
`Exec` (a reserved character the spec rejects), a dangling
`/var/lib/openbox/debian-menu.xml` reference inherited from Debian's stock
rc.xml that warned on every start, a dropbear fallback that could never fire
because the installer treats an absent package as success, the `exec startx`
login-loop hazard described above, and a pair of aliases written with
typographic quotes (U+2018/U+2019), which bash cannot parse — the generated
`~/.bashrc` aborted at that line and everything below it, including the
oh-my-posh prompt block, silently never ran.

### What the first hardware run found

The script has since been run on Raspberry Pi OS (Trixie, arm64) on a Pi 5. It
completed, with a single failure — step 22, `Failed to enable unit: Unit
dropbear.service does not exist` — which took three attempts to diagnose
correctly:

1. Guessed socket activation. Wrong: no `dropbear.socket` existed.
2. Guessed a unit-naming difference and required a unit file to be present.
   Worse — that would have reported failure on a sysvinit-only layout where
   dropbear was serving perfectly well.
3. The install log settled it: only `dropbear-bin`, `libtomcrypt1` and
   `libtommath1` were installed. `dropbear-run` was dropped from Debian in
   2022.83-3 and the `dropbear` package now ships the startup files, so nothing
   provided a service. The binary-presence probe passed and hid it.

Two fixes came out of that, both worth keeping: the step decides from **which
process owns port 22** rather than from a command's exit status, and it
verifies a service or init script exists before touching OpenSSH at all.

**Still not verified:** the fixes made after that run have not themselves been
re-run on hardware, and the Bookworm-only fallback paths — the vimb source
build and the fastfetch `.deb` download — stay untested, since Trixie packages
both.

## Second pass: `inst_dark_theme_and_icons.sh`

Run **after** `inst-min-lxqt-rpi5.sh` to apply a dark theme, Papirus icons and
a configured panel:

```bash
chmod +x inst_dark_theme_and_icons.sh
./inst_dark_theme_and_icons.sh
```

| Variable | Effect |
|---|---|
| `NO_DESKTOP=1` | Do not enable the PCManFM-Qt desktop process |
| `ASSUME_YES=1` | Never prompt (unattended run) |

| Setting | Value |
|---|---|
| GTK 2 / GTK 3 | Arc-Dark, `prefer-dark` on |
| Icons | Papirus-Dark |
| Qt widget style | `kvantum-dark`, dark Kvantum engine theme auto-selected |
| LXQt theme | `kvantum` (shipped by `lxqt-themes`) |
| Openbox | generated `Arc-Dark-Square` — square 1px borders |
| Font | Ubuntu Nerd Font 10, Normal |
| Panel | 48 px tall, 38 px icons, bottom, raspberry menu icon |
| Desktop | PCManFM-Qt, 48×48 icons, Sans 11 labels, white on `#383C48` |

### Three things the spec asked for that needed a decision

1. **`arc-theme` ships no Openbox theme** — only GTK2/3/4, metacity and xfwm4.
   So "Openbox borders in Arc-Dark" cannot be done by installing it. The script
   generates `Arc-Dark-Square` from Arc-Dark's own palette instead.
2. **Arc-Dark does not vary the titlebar background** between active and
   inactive — it uses `#2F343F` for both and distinguishes them by text colour.
   The requested "dark active, very dark inactive" therefore uses two authentic
   Arc-Dark values: `#383C4A` (background) active, `#2F343F` (headerbar)
   inactive, so nothing clashes with the GTK theme.
3. **The icon theme was specified twice, differently** — "Papirus black dark"
   in one place, "Numix Circle" in the Config Center block. Papirus-Dark is
   applied; Numix-Circle stays installed and selectable in `lxqt-config`.

### Other notes

- **`lxqt-panel` has no separator plugin.** Each requested "Separator" is a
  fixed 8 px `spacer`, which is the conventional stand-in.
- **Debian ships no `.desktop` file for urxvt**, so the script writes one into
  `~/.local/share/applications/` for the Quick Launch entry.
- **Enabling the desktop reverses a base-script decision.** `inst-min-lxqt-rpi5.sh`
  deliberately ran no desktop process and painted the background with
  `xsetroot`. Desktop icons cost roughly 30–45 MB RSS; `NO_DESKTOP=1` keeps the
  lighter arrangement and just writes the settings.
- **Run it from a TTY if you can.** LXQt rewrites `lxqt.conf` and `panel.conf`
  when the session exits, so editing them under a live session means logout
  reverts the changes. The script detects a running session and warns.
- `rc.xml` and `panel.conf` are backed up with a timestamp before being changed.

## After install

```bash
sudo reboot          # or: startx

free -h
ps -eo rss,comm --sort=-rss | head -20
```
