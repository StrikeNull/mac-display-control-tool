# Patch Notes

`changes.diff.txt` is the GitHub issue patch used to build `bin/displayplacer-patched`.

The key behavior change is:

- `validateScreenOnline(...)` always returns `true`
- resolution and rotation changes are skipped

That makes the binary useful as a rescue tool for `enabled:true`, not as a full replacement for original `displayplacer`.

