---
title: New repos in {{ env.GITHUB_REPOSITORY_OWNER }} found
---

Review new discovered repositories during run {{ env.GITHUB_SERVER_URL }}/{{ env.GITHUB_REPOSITORY }}/actions/runs/{{ env.GITHUB_RUN_ID }}:

```
{{ env.NEW_REPOSITORIES }}
```

And add them to `cimas-config/cimas.yml` with right set of `files`