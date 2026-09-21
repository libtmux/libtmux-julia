import { readFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const [root, corpusFile] = process.argv.slice(2);
if (!root || !corpusFile) throw new Error("expected sibling root and corpus file");
const source = join(root, "packages/libtmux/src");
const { decodeWhereDocument, encodeWhereDocument } = await import(
  pathToFileURL(join(source, "selection.ts")).href
);
const { compileWhere } = await import(
  pathToFileURL(join(source, "_internal/selection/compile.ts")).href
);
const corpus = JSON.parse(readFileSync(corpusFile, "utf8"));
const records = corpus.panes.map((pane: Record<string, unknown>) => ({
  model: "pane",
  adjacency: [],
  scalars: Object.fromEntries(Object.entries(pane).map(([key, value]) => [
    key, typeof value === "boolean" ? (value ? "1" : "0") : String(value),
  ])),
}));
const valid = corpus.valid.map((fixture: any) => {
  const decoded = decodeWhereDocument(fixture.typescript);
  const predicate = compileWhere(decoded.model, decoded.where);
  return {
    id: fixture.id,
    selected: records.filter((record: any) => predicate.matches(record, () => undefined))
      .map((record: any) => record.scalars.pane_id),
    canonical: JSON.parse(encodeWhereDocument(decoded)),
  };
});
const invalid = corpus.invalid.map((fixture: any) => {
  try {
    decodeWhereDocument(fixture.typescript);
    return { id: fixture.id, rejected: false };
  } catch {
    return { id: fixture.id, rejected: true };
  }
});
process.stdout.write(JSON.stringify({ valid, invalid }));
