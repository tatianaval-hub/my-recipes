#!/usr/bin/env bash
set -euo pipefail

mkdir -p .build-supabase dist/vendor

cd .build-supabase
npm init -y
npm install --save-exact \
  @supabase/supabase-js@2.118.0 \
  esbuild@0.25.0

printf '%s\n' \
  'export { createClient } from "@supabase/supabase-js";' \
  > entry.js

./node_modules/.bin/esbuild entry.js \
  --bundle \
  --platform=browser \
  --format=esm \
  --target=es2022 \
  --legal-comments=inline \
  --metafile=meta.json \
  --outfile=../dist/vendor/supabase.js

node --input-type=module <<'JS'
import fs from 'node:fs';

const meta = JSON.parse(fs.readFileSync('meta.json', 'utf8'));
for (const output of Object.values(meta.outputs)) {
  for (const dependency of output.imports) {
    if (dependency.external) {
      throw new Error('External dependency: ' + dependency.path);
    }
  }
}
JS

cd ..

node --input-type=module <<'JS'
import fs from 'node:fs';

const source = fs.readFileSync('index.html', 'utf8');
const oldImport =
  "import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';";
const newImport =
  "import { createClient } from './vendor/supabase.js';";

let html;

if (source.split(oldImport).length === 2) {
  html = source.replace(oldImport, newImport);
} else if (source.includes(newImport)) {
  html = source;
} else {
  throw new Error('Не найдено ожидаемое подключение Supabase.');
}

if (html.includes('esm.sh/')) {
  throw new Error('В HTML осталось подключение esm.sh.');
}

fs.writeFileSync('dist/index.html', html);
console.log('Готово: dist/index.html и dist/vendor/supabase.js');
JS
