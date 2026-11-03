# Fonts

The theme asks for General Sans (display), DM Sans (body) and JetBrains Mono (code), per
`docs/gui/design-reference.md`. Font files are not committed. Drop the `.ttf`/`.otf` files in this
folder and `Start-M365Gui.ps1` rebinds the three font families with this folder as the base
URI. Without them, WPF falls back to Segoe UI Variable / Segoe UI and Cascadia Mono / Consolas,
which keeps the layout intact.

Sources: General Sans from Fontshare (free license), DM Sans and JetBrains Mono from Google
Fonts (OFL). Check the license text that ships with each download before redistributing.
