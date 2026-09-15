# Local checks

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests -v
bash build.sh
"../Codex Dial.app/Contents/MacOS/CodexDial" --self-test
"../Codex Dial.app/Contents/MacOS/CodexDial" --render /tmp/dial-previews
```

Python tests use a temporary socket and synthetic app bundles; they do not touch
real Codex sessions. Swift checks use preview state and temporary preset files.

The desktop adapter opens a connection only for an explicit action, discovers
that session's owner, follows its state, and closes the connection afterward.
Read/prepare failures retry once. A write whose response is lost is never replayed.

Protocol versions come from the installed app's local version table, cached by
archive path, inode, size and modification time. Updating Codex invalidates that
cache on the next action. JS is read as data, never executed or modified.

The original v1 settings contract is supported. v2 and later versions require
the known settings handler structure to match, allowing renamed minified locals.
Tests cover compatible synthetic v3/v4 tables and rejection of a changed handler.
This is not a guarantee of compatibility with arbitrary future Codex changes:
changed semantics or an unrecognized bundle format still require adaptation.

Real desktop checks should separately cover A → B → A reads, current-window
identification, and physical shortcuts. The isolated tests do not prove those
UI integration paths. An empty settings request with a guaranteed nonmatching
condition can check the real v2 endpoint without applying a model change.
