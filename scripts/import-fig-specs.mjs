// Converts Fig's open-source completion specs (MIT, github.com/withfig/autocomplete) into the
// compact JSON Rune bundles: subcommands, flags, descriptions and static argument values.
// Generators (shell commands run while you type) are left out.
//   npm pack @withfig/autocomplete && tar xzf withfig-autocomplete-*.tgz
//   node scripts/import-fig-specs.mjs package/build Resources/Completions/fig-specs.deflate
// The JSON is stored raw-DEFLATE compressed (about a sixth of the size); Rune inflates it
// with NSData's .zlib decompression.
import { readdirSync, writeFileSync, statSync } from "node:fs";
import { deflateRawSync } from "node:zlib";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const [buildDir, outFile] = process.argv.slice(2);
const MAX_DEPTH = 5;
const MAX_DESCRIPTION = 90;

const names = (value) => (Array.isArray(value) ? value : [value]).filter((n) => typeof n === "string" && n.length > 0);
const describe = (text) => {
  if (typeof text !== "string") return undefined;
  const line = text.split("\n")[0].trim().replace(/\.$/, "");
  if (!line) return undefined;
  return line.length > MAX_DESCRIPTION ? line.slice(0, MAX_DESCRIPTION - 1) + "…" : line;
};

// The argument of a command or option: "f" files, "d" folders, or a list of fixed values.
function argument(args) {
  const list = (Array.isArray(args) ? args : [args]).filter(Boolean);
  const first = list[0];
  if (!first || typeof first !== "object") return undefined;
  const templates = names(first.template);
  if (templates.includes("folders") && !templates.includes("filepaths")) return "d";
  if (templates.includes("filepaths")) return "f";
  const values = (Array.isArray(first.suggestions) ? first.suggestions : [])
    .flatMap((s) => (typeof s === "string" ? [s] : names(s?.name)))
    .slice(0, 60);
  return values.length ? values : undefined;
}

function convert(spec, depth) {
  const node = {};
  const n = names(spec.name);
  if (n.length) node.n = n;
  const d = describe(spec.description);
  if (d) node.d = d;
  if (depth < MAX_DEPTH && Array.isArray(spec.subcommands)) {
    const subs = spec.subcommands.filter((s) => s && typeof s === "object" && !s.hidden && names(s.name).length).map((s) => convert(s, depth + 1));
    if (subs.length) node.s = subs;
  }
  if (Array.isArray(spec.options)) {
    const options = spec.options
      .filter((o) => o && typeof o === "object" && !o.hidden && names(o.name).length)
      .map((o) => {
        const entry = [names(o.name)];
        const od = describe(o.description);
        if (od) entry.push(od);
        return entry;
      });
    if (options.length) node.o = options;
  }
  const a = argument(spec.args);
  if (a) node.a = a;
  return node;
}

const specs = {};
let skipped = 0;
for (const file of readdirSync(buildDir).sort()) {
  if (!file.endsWith(".js") || file.startsWith("-") || file.startsWith("@")) continue;
  const path = join(buildDir, file);
  if (!statSync(path).isFile()) continue;
  try {
    const module = await import(pathToFileURL(resolve(path)).href);
    const spec = module.default;
    if (!spec || typeof spec !== "object" || names(spec.name).length === 0) { skipped++; continue; }
    const converted = convert(spec, 0);
    for (const name of names(spec.name)) specs[name] = converted;
  } catch {
    skipped++;
  }
}
writeFileSync(outFile, deflateRawSync(Buffer.from(JSON.stringify(specs)), { level: 9 }));
console.log(`${Object.keys(specs).length} commands written, ${skipped} skipped`);
