# NitroAI native transfer oracle

This is a bounded Electron regression oracle for the transfer contract. It is
not computer-use acceptance and it does not read a real profile. Source and
destination use separate private `userData` and `sessionData` roots, reused only
for their restart assertions. Children load the current built `dist`, allow
only that profile's read-only assets and health endpoint, and quit after each
compound action. The registered copy is pinned against maker edits.

The expected JSON file is exactly the v1 library envelope:

```json
{"format":"nitroai-library","version":1,"notes":[/* Note[] */],"folders":[/* Folder[] */]}
```

Envelope validation retains and checks each Note's `sourceMeta` when present
and every block's `id`, `type`, and `text`; fixture variants copy those fields
rather than reconstructing notes from rendered text. Visible readback proves
title, body, membership, and stable route IDs, while the file assertion proves
the richer exported Note payload crossed the file boundary.

The journey seeds notes through the real Blank document, editor, New Folder,
and move-to-folder controls. Export must be a real `will-download` event saved
to a fixed scratch path. Import must be the real Settings control plus a
`File`/`DataTransfer` event on its file input. The oracle never writes
IndexedDB records directly. Readback opens notes and folder filters through
the visible app after fresh relaunches. Accepted imports do not infer success
from a short timer or from the absence of an error: the fixture waits for a
new accessible import-completion status and for all imported labels to become visible in the
Dashboard, then the parent test reads them again from a new Electron process.
Rejected imports require a newly mutated `role="alert"`. An unrelated DOM
mutation with an old alert does not establish rejection.

The compound test covers source preservation, two durable profile roots,
duplicate import by identity, a different identity with the same visible note
title, two folders with equal names and equal `createdAt` but different IDs,
malformed and wrong-format rejection, and a real one-shot IndexedDB abort from
the original `IDBObjectStore.put`/`add` success path. The abort case must show a
visible `role="alert"` and leave no partial imported note or folder after
restart. A missing control, missing error signal, unsupported format, or failed
transaction hook is a reported failure, never a skip.

The lab source also transfers the receiving library onward into a third private
profile, repeats the original collision file, restarts that profile and repeats
again. Complete exported records must stay unchanged, apart from the normal
view timestamp. A final same-ID note with changed body, metadata and edit time
must be retained alongside the unchanged original. This rejects ID-only skipping
as well as lost conflict identity. These additions are staged in test-only
baseline `d9d346d91e4801ce9267d8d8dffe4d5953f26f27`, but not yet accepted
against a generated feature.

The staged entry imports both the existing persistence suite and this oracle.
Run from the isolated NitroAI clone using its installed Vitest runtime and an
explicit approved fixture root. There is no user-profile default:

```sh
IRIS_NITROAI_TARGET_ROOT=/approved/fixture-root node --no-experimental-webstorage node_modules/vitest/vitest.mjs run server/desktop-persistence.test.mjs --maxWorkers=1
```

The same `IRIS_NITROAI_TARGET_ROOT` value must be present in the environment
inherited by the Electron child processes. A missing or non-absolute value is
an intentional setup failure.

The separate `readiness` action onboards with Codex CLI, creates a real note and
folder, moves the note through its row menu, and reopens both visibly. It does
not prove export/import behavior. Existing NitroAI persistence tests remain
required; this oracle adds transfer behavior coverage and does not replace
computer-use acceptance of the installed app.

September 11 baseline observation: the registered entry ran seven tests in
10.8 seconds. Six passed; the transfer journey failed on the absent
`Export notes and folders` control. No test was skipped. Readiness uses DOM
input/focus events, including an explicit bubbling focusout event because the
hidden Electron window does not emit it reliably; it is not native keyboard
or native file-dialog evidence. Successful transfer and its edge cases remain
unproven until Iris produces the feature and the full journey passes.
