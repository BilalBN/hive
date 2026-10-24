# Contributing

Thank you for wanting to help. Hive is a family music server first: changes
should keep it simple for the person who runs it and private for the family.

- **Bugs and ideas:** open an issue (the templates ask the useful
  questions). For security problems see SECURITY.md.
- **Code:** fork, branch, and open a pull request. CI runs everything; run
  the relevant tests locally first:
  - server: `cd server && .venv/bin/ruff check hive tests && .venv/bin/python -m pytest`
  - Hive Admin: `cd admin && npm test && npm run typecheck`
  - app: `cd app && flutter analyze && flutter test`
- **Changing the API:** edit `api/openapi.yaml` first, then regenerate the
  clients (`python3 tools/gen_dart_client.py`, `npm run gen:api --prefix
  admin`); never edit the generated files by hand.
- **Words on screen** are plain and short ("Couldn't reach home", not "Error
  503"). Nothing sent outside home may carry personal details.

By contributing you agree your work is published under the AGPL-3.0, as the
rest of Hive.
