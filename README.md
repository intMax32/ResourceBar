# ResourceBar

Small macOS menu bar app that shows current CPU usage as the menu bar title.
Click the menu bar percentage to open a compact toolbar with CPU, RAM, GPU usage, and the top resource-consuming apps/processes.

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
- CPU and RAM Top 3 lists are sampled with macOS `libproc` process counters and grouped by `.app` bundle name when possible.
- GPU usage uses IOKit `PerformanceStatistics` counters when macOS exposes them. Some Mac models or macOS versions may not expose a public percentage, in which case the app shows `N/A`.
- Per-app GPU Top 3 is not exposed through stable public macOS APIs, so the GPU tile only shows the overall GPU counter.
