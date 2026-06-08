# ResourceBar

Small macOS menu bar app that shows current CPU usage as the menu bar title.
Click the menu bar percentage to open a compact toolbar with CPU, RAM, and GPU usage.

## Build

```sh
scripts/build-app.sh
```

The app bundle is generated at:

```text
dist/ResourceBar.app
```

## Run

```sh
open dist/ResourceBar.app
```

The app runs as a menu bar accessory. Use the popover's `Quit` button to close it.

## Notes

- CPU is sampled from Mach processor load counters.
- RAM uses Mach VM statistics and counts internal, wired, and compressed memory as used. File cache and purgeable memory are shown as cache instead of being counted as hard-used memory.
- GPU usage uses IOKit `PerformanceStatistics` counters when macOS exposes them. Some Mac models or macOS versions may not expose a public percentage, in which case the app shows `N/A`.
