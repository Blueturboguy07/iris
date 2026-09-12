const folder = (id, name, createdAt) => ({ id, name, createdAt });
const paragraph = (id, text) => ({ id, type: "paragraph", text });
const todo = (id, text, checked) => ({ id, type: "todo", text, checked });
const table = (id) => ({ id, type: "table", text: "", rows: [["key", "value"], ["a", "1"]] });
const note = (id, title, sourceText, folderId, at, blocks, extra = {}) => ({
  id, title, sourceKind: "text", sourceText, blocks, folderId,
  createdAt: at, updatedAt: at + 1000, lastOpenedAt: at + 2000, ...extra,
});
const envelope = (folders, notes) => ({ format: "nitroai-library", version: 1, folders, notes });

const equalNameTime = envelope(
  [
    folder("10000000-0000-4000-8000-000000000001", "Research", 1700000000000),
    folder("10000000-0000-4000-8000-000000000002", "Research", 1700000000000),
  ],
  [
    note("10000000-0000-4000-8000-000000000011", "Same title", "alpha body", "10000000-0000-4000-8000-000000000001", 1700000001000, [
      todo("10000000-0000-4000-8000-000000000021", "alpha todo", true),
      table("10000000-0000-4000-8000-000000000022"),
    ], { sourceMeta: { filename: "alpha.txt", duration: 3 } }),
    note("10000000-0000-4000-8000-000000000012", "Same title", "beta body", "10000000-0000-4000-8000-000000000002", 1700000001000, [
      paragraph("10000000-0000-4000-8000-000000000023", "beta body"),
    ], { sourceMeta: { url: "https://example.invalid/beta" } }),
  ],
);

const folderCollision = envelope(
  [folder("20000000-0000-4000-8000-000000000001", "Incoming", 1700000010000)],
  [note("20000000-0000-4000-8000-000000000011", "Incoming note", "incoming body", "20000000-0000-4000-8000-000000000001", 1700000011000, [
    paragraph("20000000-0000-4000-8000-000000000021", "incoming body"),
  ])],
);

const repeatAfterOpen = envelope(
  [folder("30000000-0000-4000-8000-000000000001", "Stable", 1700000020000)],
  [note("30000000-0000-4000-8000-000000000011", "Stable note", "same body", "30000000-0000-4000-8000-000000000001", 1700000021000, [
    paragraph("30000000-0000-4000-8000-000000000021", "same body"),
  ])],
);

const abortInput = envelope(
  [
    folder("50000000-0000-4000-8000-000000000001", "Abort A", 1700000040000),
    folder("50000000-0000-4000-8000-000000000002", "Abort B", 1700000041000),
  ],
  [
    note("50000000-0000-4000-8000-000000000011", "Abort A", "abort a", "50000000-0000-4000-8000-000000000001", 1700000042000, [paragraph("50000000-0000-4000-8000-000000000021", "abort a")]),
    note("50000000-0000-4000-8000-000000000012", "Abort B", "abort b", "50000000-0000-4000-8000-000000000002", 1700000042000, [paragraph("50000000-0000-4000-8000-000000000022", "abort b")]),
  ],
);

export const transferNativeOracleCases = {
  format: "nitroai-transfer-native-oracle",
  version: 1,
  scope: ["notes", "folders"],
  cases: [
    { id: "distinct-equal-name-time-folders", operation: "import", input: equalNameTime },
    { id: "destination-folder-id-collision", operation: "import", input: folderCollision },
    { id: "same-content-reimport-after-open", operation: "import", input: repeatAfterOpen },
    { id: "partial-transaction-abort", operation: "import", input: abortInput },
    {
      id: "malformed-or-unsupported-envelope", operation: "import",
      rawInputs: [
        '{"format":"nitroai-library","version":1,"folders":[',
        '{"format":"other-library","version":1,"folders":[],"notes":[]}',
        '{"format":"nitroai-library","version":2,"folders":[],"notes":[]}',
      ],
    },
    {
      id: "untrusted-duplicate-and-dangling-relationship", operation: "import",
      variants: [
        {
          id: "duplicate-folder-id",
          input: envelope([
            folder("60000000-0000-4000-8000-000000000001", "First", 1700000050000),
            folder("60000000-0000-4000-8000-000000000001", "Second", 1700000051000),
          ], []),
        },
        {
          id: "dangling-folder-reference",
          input: envelope(
            [folder("60000000-0000-4000-8000-000000000003", "Known", 1700000050000)],
            [note("60000000-0000-4000-8000-000000000011", "Untrusted", "untrusted", "60000000-0000-4000-8000-000000000004", 1700000052000, [paragraph("60000000-0000-4000-8000-000000000021", "untrusted")])],
          ),
        },
      ],
    },
  ],
};
