const fs = require("fs").promises;
const path = require("path");

function parseBlockDocstring(docstring) {
  docstring = docstring.map((s) => s.replace(/^\/\/ ?/, "")).join("\n");

  const tags = {};
  const store = (tag, value) => {
    if (!tags[tag]) tags[tag] = [];
    tags[tag].push(value);
  };

  let tagStart = (tagEnd = null);
  while (true) {
    const nextTagStart = docstring.indexOf("@", tagEnd);
    if (nextTagStart === -1) break;

    if (tagEnd)
      store(docstring.slice(tagStart, tagEnd), docstring.slice(tagEnd + 1, nextTagStart).trim());

    tagStart = nextTagStart;
    tagEnd = Math.min(docstring.indexOf(" ", tagStart), docstring.indexOf("\n", tagStart));
  }

  store(docstring.slice(tagStart, tagEnd), docstring.slice(tagEnd + 1).trim());

  return tags;
}

async function readBlockDocstring(filepath) {
  const lines = (await fs.readFile(filepath, "utf8")).split("\n");

  if (!lines[0].includes("@block")) return null;

  let i = 1;
  for (; i < lines.length; i++) {
    if (!lines[i].startsWith("//")) break;
  }

  return lines.slice(0, i + 1);
}

async function crawlBlockDocstrings(dir) {
  var paths = [];
  for (const filename of await fs.readdir(dir)) {
    const p = path.join(dir, filename);
    const stat = await fs.stat(p);

    if (stat.isDirectory()) {
      paths = paths.concat(await crawlBlockDocstrings(p));
    } else if (stat.isFile()) {
      paths.push(p);
    }
  }

  return paths;
}

module.exports = async function () {
  const blocks = {};

  for (const path of await crawlBlockDocstrings("../src/blocks")) {
    const docstring = await readBlockDocstring(path);
    if (!docstring) continue;

    const tags = parseBlockDocstring(docstring);

    if (!blocks[tags["@category"][0]]) blocks[tags["@category"][0]] = {};

    blocks[tags["@category"][0]][tags["@block"][0]] = tags;
  }

  return { blocks };
};
