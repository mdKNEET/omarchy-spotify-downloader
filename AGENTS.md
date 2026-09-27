# Agent guidelines

## Writing style

- No em dashes (—) anywhere: not in UI copy, code comments, commit messages,
  documentation or replies. Use a comma, colon, full stop or parentheses
  instead. The same goes for an en dash (–) used as a sentence dash.

## GitHub attribution

End every commit message, PR description, PR/issue comment and review comment
posted on behalf of @mdKNEET with:

```
🤖 <agent name>, posting on behalf of @mdKNEET
```

## Project notes

- SMB destinations must go through `gio` (see `spotdl-job.sh`), never through
  the `/run/user/$UID/gvfs/...` FUSE path: without `gvfsd-fuse` that path is
  plain tmpfs and files silently end up in RAM instead of on the server.
