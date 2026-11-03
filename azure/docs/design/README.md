# Design references

Design systems the GUI is styled against. `scripts/powershell/gui/Theme.xaml` is the
only file that has to change when one of these changes: its token block maps the
design's palette, type and radii onto WPF resources.

| File | Used by | Notes |
| ---- | ------- | ----- |
| `ember-studio.md` | `gui/Theme.xaml` | Warm light theme. Fonts are Google Fonts; install Playfair Display, Source Sans 3 and Fira Code on Windows for the full look, otherwise the theme falls back to Georgia, Segoe UI and Cascadia Mono. |
