---
title: New repos in {{ env.GITHUB_REPOSITORY_OWNER }} found
---

Review new discovered repositories during run {{ env.GITHUB_SERVER_URL }}/{{ env.GITHUB_REPOSITORY }}/actions/runs/{{ env.GITHUB_RUN_ID }}:

<!---
There is no way to pass multiline variable to render it correctly so placeholder below will be replaced by sed
-->
REPOSITOY_MARKDOWN_LIST

And add them to `cimas-config/cimas.yml` with the right set of `files`