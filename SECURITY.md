# Security

Please report security problems privately: use **GitHub → Security →
Report a vulnerability** on this repository (a private advisory), not a
public issue. Include what you found, how to reproduce it, and the version.
You'll get an answer within a week.

Hive's design, for context: the server listens only on localhost and the
Tailscale address; every person is invited and every device approved; apps
sign each request with a key that never leaves the device; Hive Admin away
from the home computer needs an email code (and an authenticator app if set
up). The API contract is `api/openapi.yaml`.
