# Design

`tokens.json` is the single source for Hive's colours, type, spacing, radii and
motion. `lucide-icons.json` maps Lucide icon names to the codepoints in the
bundled icon font. After editing either, run:

```sh
python3 tools/gen_design.py
```

which rewrites `app/lib/design/tokens.g.dart`, `app/lib/design/icons.g.dart`
and `admin/src/styles/tokens.css`. CI fails if they are out of date.

The colour values are the contrast-checked set from the second design review:
every text colour passes WCAG AA on the surfaces it is used on.
