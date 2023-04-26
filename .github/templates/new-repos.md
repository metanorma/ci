---
title: New repos in {{ env.GITHUB_ORGANISATION }} found
---

Review new discovered repositories during run {{ env.GITHUB_SERVER_URL }}/{{ env.GITHUB_REPOSITORY }}/actions/runs/{{ env.GITHUB_RUN_ID }}:

```
{{ env.YAML_DIFF }}
```

And add them to `cimas-config/cimas.yml` with right set of `files`