# Fixture anonymization

The logs, build descriptions, stats files and stdout excerpts under `fixtures/` were recorded from real builds of a
private app on a developer Mac. Before the repository went public, every private identifier in them, and in the
tests that pin their strings, was replaced with a neutral token by `Scripts/anonymize-fixtures.py`. Timings,
task counts, the task DAG, signatures and every other byte of structure are unchanged.

## Replacement table

The original values are not recorded here or anywhere else in the repository: the script reads them from a private
JSON file (`{"<role>": "<original>"}`) kept outside the repo. Each replacement has the same UTF-8 length as the
original. Roles with case forms are replaced as written, in lower case, in upper case and capitalized.

| Role | Replacement | Case forms | What it stood for | Where it occurred |
|---|---|---|---|---|
| `project` | `AcmeApp` / `acmeapp` | yes | the app's project, scheme, target and module name; its repo folder and DerivedData folder | all log fixtures, build descriptions, `deep/stats` (contents and file names), tests |
| `account` | `ciuser` | yes | the macOS account name: home folder, `PATH`, scratch and DerivedData paths, Finder breadcrumbs | all log fixtures, build descriptions, `deep/ftime-trace`, tests |
| `email` | `acmebuilder` | yes | the e-mail local part | no occurrence in fixtures or tests (kept for re-runs) |
| `host` | `Build-Host-Mac-01` | no | the host name | no occurrence (kept for re-runs) |
| `hostLocal` | `BuildHostMac001` | no | the Bonjour local host name | no occurrence (kept for re-runs) |
| `person` | `Jamie` | yes | the owner's first name | no occurrence (kept for re-runs) |

No Apple team ID, provisioning profile, personal code-signing identity, API key or token occurs in the fixtures
(the builds were signed "to run locally"); the audit below checks for them.

The project replacement is the same token as the synthetic `fixtures/projects/AcmeApp` project, but nothing links
the two: the logs name `/Users/ciuser/Projects/acmeapp`, a path that does not exist.

## Files rewritten (105)

| Type | Files |
|---|---|
| `.xcactivitylog` (gzip SLF) | 35, in `fixtures/logs/*` |
| `manifest.json.gz`, `xcresult-buildlog*.json.gz` | 11 |
| `LogStoreManifest.plist` | 10 |
| `.json` (`build-request.json`, `cli-xcode26/xcbuilddata/manifest.json`, `deep/stats/*`, `deep/ftime-trace/*`) | 15 (the 6 `deep/stats` files also renamed) |
| `.txt` (`target-graph.txt`, `xcodebuild-stdout-inc2-excerpt.txt`), `build26.log`, `build27.log`, `.resp` | 11 |
| `Tests/**/*.swift` (expected strings) | 23 |

`SIGNATURE` files, `clangmodulesreport`/`swiftmodulesreport` CSVs and `fixtures/projects/**` contained no private
identifier and are unchanged.

## Encodings

Names hide in four encodings, and each is rewritten in its own form:

1. Plain bytes (paths, titles, command lines, JSON).
2. Base64 strings inside SLF strings (JSON blobs naming the workspace and its DerivedData folder).
3. Hex strings: the task-signature slot of each SLF section is a prefix byte plus the task key, hex-encoded.
4. JSON arrays of byte values: task keys in Task Backtrace attachments (`*-why` logs and their `xcresult` JSON).

The first three keep their length. A byte array's decimal text can change length (`111` becomes `99`), so the script
rewrites SLF streams token by token: a string or JSON token whose payload changed is re-emitted with its new length
prefix (`<len>"<bytes>`, `<len>*<json>`), every other byte is copied, and the result is re-tokenized to the end.
Six `*-why` logs and the two `xcresult-buildlog-inc.json.gz` files are 1 to 509 bytes shorter for that reason;
the other 38 gzip fixtures inflate to exactly their original length. Gzip files are re-compressed with mtime 0.

## Verification

- `xcblame analyze <log> --format json --no-env --no-history --no-rules --offline` on all 35 logs, before and after,
  with the table applied to the "before" strings: identical reports (same task counts, wall, critical path,
  rollups, causes, findings), no numeric differences.
- `swift test`: all tests pass with the updated expectations; no assertion was removed or loosened.
- `Scripts/anonymize-fixtures.py --check --private-map <file> fixtures Tests Sources Scripts` searches every file,
  inflated, in all four encodings plus UTF-16, for each original (any case) and for generic leaks (another
  account's `/Users/<name>`, a personal mail address, a `DEVELOPMENT_TEAM`); `--check` alone runs the generic part.

## Re-running

```sh
Scripts/anonymize-fixtures.py --private-map ~/path/to/private-map.json            # fixtures and Tests
Scripts/anonymize-fixtures.py --check --private-map ~/path/to/private-map.json    # audit, exit 1 on a leak
```

Run it on new recordings before committing them; it is idempotent. Never commit the original logs.
