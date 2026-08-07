::notice title=Version advisory::Detected changes suggest 'minor'. You selected 'patch'. See run summary.


## Version advisory

Range: v0.1.0 → HEAD
Overall suggested bump: **minor**
You selected: `patch`.

| Change | Classification | Evidence | Suggested |
|---|---|---|---|
| Signature-changed `Foo::transform` | public | annotation `# @api public` at lib/foo.rb:5; demoted major→minor per pre-1.0 SemVer convention | minor |

_Advisory only. Maintainer selects the bump. See ci#369 for the design brief._
