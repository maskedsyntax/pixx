# pixx

Color picker for Linux. Run it, click somewhere, get the hex value of that
pixel in your clipboard.

Works on X11 and Wayland (through the desktop portal).

## Usage

```
pixx            # prints #1e90ff and copies it
pixx -f rgb     # rgb(30, 144, 255)
pixx -f hsl     # hsl(210, 100%, 56%)
pixx -n         # don't copy, just print
```

On X11 you get a crosshair and a small zoomed view next to the cursor. Click,
Enter or Space picks. Arrow keys (or hjkl) move the cursor one pixel at a time,
ten with Shift. Esc or right click cancels.

On Wayland your compositor shows its own picker instead.

pixx exits with 0 when a color is picked, 1 when cancelled and 2 on errors, so
it's easy to use in scripts:

```
color=$(pixx --no-notify) && echo "$color"
```

See `pixx --help` for the rest of the options.

## Building

You need Zig 0.17 and the X11 and D-Bus headers.

```
sudo apt install libx11-dev libdbus-1-dev    # Debian / Ubuntu / Mint
sudo pacman -S libx11 dbus                   # Arch
sudo dnf install libX11-devel dbus-devel     # Fedora
```

Then:

```
zig build -Doptimize=ReleaseSafe
cp zig-out/bin/pixx ~/.local/bin/
```

On Wayland, copying needs `wl-copy` from wl-clipboard.

## Notes

On X11, pixx keeps a tiny process running in the background after you pick,
because X only keeps clipboard contents around while the program that set them
is alive. It goes away as soon as you copy something else.

It's handiest bound to a key. I use Super+Shift+C.
