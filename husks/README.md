# Public husk gems

This directory holds the source of record for **public RubyGems husk gems** maintained by the metanorma org. Husks are deprecation-stub gems published to public RubyGems so that the resolver picks them over older 2019-era public versions of gems whose active development has since moved private. They have no runtime dependencies and no functional code — just a deprecation `warn` on load pointing at the private GitHub Packages source.

## Why these exist

Around 2019, several metanorma flavour repos were privatised at the request of their sponsoring standards bodies. Active development moved to private GitHub Packages publishing. But the existing public RubyGems entries for those gems were left in place at their last 2019/2020/2021-era version, with 2019/2020/2021-era dependency pins. Anyone running `gem install metanorma-<flavour>` from public — without scoping to the private GH Packages source — gets that ancient version, which drags the entire downstream metanorma stack backwards by years.

The husk strategy fixes this by publishing a NEW public version that is:

- **Above** the current public husk version (so the resolver picks it for fresh `gem install`)
- **In a version gap** the private team won't use (so we don't shadow any real private release)
- **Below** the active private major (so anyone pinning to the active major continues to get the private gem via GH Packages, untouched)

The husk loads with a clear deprecation warning explaining the private-source migration path.

## Current husks

| Gem | Husk version | Replaces public | Tracking issue |
|---|---|---|---|
| `metanorma-nist` | `1.5.0` | `1.3.2` (2021-05-25, 2021-era pins) | [`metanorma/metanorma-nist#497`](https://github.com/metanorma/metanorma-nist/issues/497) |
| `metanorma-bsi` | `0.7.0` | `0.0.1` (2021-04-25, never-functional placeholder) | [`metanorma/metanorma-bsi#625`](https://github.com/metanorma/metanorma-bsi/issues/625) |

Both were surfaced via triage of [`metanorma/metanorma#568`](https://github.com/metanorma/metanorma/issues/568) (Peter Wyatt, PDF Association), even though that ticket's actual bug was unrelated env-orphan gems on the reporter's side.

## Build + push

From each husk directory:

```sh
cd husks/metanorma-nist
gem build metanorma-nist.gemspec
gem push metanorma-nist-1.5.0.gem
```

Requires a RubyGems API key with publish rights on the `metanorma-nist` (resp. `metanorma-bsi`) gem name, in `~/.gem/credentials`.

## When to add a husk here

Only when a metanorma-org gem has:

1. An existing public RubyGems version with stale 2019-2021-era dependency pins, AND
2. Active development that has moved to a private GitHub Packages source, AND
3. A real risk of external consumers being dragged backwards by `gem install <name>` from public.

Audit of all 20 metanorma flavour repos (2026-06-28) confirmed `metanorma-nist` and `metanorma-bsi` are currently the only two fitting this pattern. Other stale public versions exist (gb, vg, m3d, mpfa, m3aawg) but those repos are archived and not on the release path, so they are not husk candidates.
