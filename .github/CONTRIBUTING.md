# Contributing

Contributions are welcome, under the [MIT license](../LICENSE.md) like the rest of the repo. No CLA.

1. Open an issue first, and say what you want to change and why.
2. Then send a small pull request with that one change.

Before a pull request, run:

```bash
bash -n eeploi-helper
shellcheck eeploi-helper tests/run.sh bin/release
bash tests/run.sh
```

CI runs these on every pull request; `.github/workflows/ci.yml` lists them.

Report a security problem as the [security policy](SECURITY.md) describes, never in an issue or a pull request.

Never put server names, IP addresses or secrets in an issue or a pull request. Use fictional ones, such as `shop.example` and the documentation IP ranges.
