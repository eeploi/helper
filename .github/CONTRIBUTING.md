# Contributing

Contributions are welcome. eeploi-helper is MIT licensed, and so is what you contribute. There is no CLA.

1. Open an issue first, so we can agree on the change.
2. Then send a small pull request for it.

Before you open a pull request, run:

```bash
bash -n eeploi-helper
shellcheck eeploi-helper tests/run.sh bin/release
bash tests/run.sh
```

A security problem never goes in an issue or pull request. Report it privately, as [SECURITY.md](SECURITY.md) describes.

Never put server names, IP addresses or secrets in an issue or pull request.
