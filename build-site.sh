#!/usr/bin/env bash
set -euo pipefail

# Всегда работаем из папки, в которой находится скрипт.
cd "$(dirname "${BASH_SOURCE[0]}")"

mkdir -p build-supabase dist

cd build-supabase
npm init -y
npm install --save-exact \
  @supabase/supabase-js@2.118.0 \
  esbuild@0.25.0

# Извлекаем код приложения из исходного HTML.
node --input-type=module <<'JS'
import fs from 'node:fs';

const source = fs.readFileSync('../index.html', 'utf8');
const modulePattern = /<script\b[^>]*\btype\s*=\s*["']module["'][^>]*>([\s\S]*?)<\/script\s*>/gi;
const modules = [...source.matchAll(modulePattern)];

if (modules.length !== 1) {
  throw new Error(
    'Ожидался ровно один <script type="module"> в index.html.'
  );
}

const module = modules[0];
let app = module[1];

const expectedImports = [
  "import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';",
  "import { createClient } from './vendor/supabase.js';"
];

const foundImports = expectedImports.filter(text => app.includes(text));

if (foundImports.length !== 1) {
  throw new Error('Не найдено единственное ожидаемое подключение Supabase.');
}

const oldImport = foundImports[0];

if (app.split(oldImport).length !== 2) {
  throw new Error('Подключение Supabase встречается больше одного раза.');
}

app = app.replace(
  oldImport,
  'import { createClient } from "@supabase/supabase-js";'
);

const marker = '<!-- INLINE_APP_BUNDLE -->';

if (source.includes(marker)) {
  throw new Error('Служебная метка уже присутствует в index.html.');
}

const template =
  source.slice(0, module.index) +
  marker +
  source.slice(module.index + module[0].length);

fs.writeFileSync('app-entry.js', app);
fs.writeFileSync('page-template.html', template);
JS

# Собираем приложение и все его зависимости в один модуль.
./node_modules/.bin/esbuild app-entry.js \
  --bundle \
  --minify \
  --platform=browser \
  --format=esm \
  --target=es2022 \
  --legal-comments=inline \
  --metafile=app-meta.json \
  --outfile=app-bundle.js

# Проверяем зависимости и встраиваем сборку в HTML.
node --input-type=module <<'JS'
import fs from 'node:fs';

const meta = JSON.parse(fs.readFileSync('app-meta.json', 'utf8'));

for (const output of Object.values(meta.outputs)) {
  for (const dependency of output.imports) {
    if (dependency.external) {
      throw new Error('Внешняя зависимость: ' + dependency.path);
    }
  }
}

const template = fs.readFileSync('page-template.html', 'utf8');
const bundle = fs.readFileSync('app-bundle.js', 'utf8');

if (!bundle.trim()) {
  throw new Error('Сборка приложения пуста.');
}

// Не допускаем преждевременного закрытия script внутри HTML.
const safeBundle = bundle.replace(/<\/script/gi, '<\\/script');

const marker = '<!-- INLINE_APP_BUNDLE -->';
const parts = template.split(marker);

if (parts.length !== 2) {
  throw new Error('Не найдена единственная метка для вставки приложения.');
}

const html =
  parts[0] +
  '<script type="module">\n' +
  safeBundle +
  '\n</script>' +
  parts[1];

if (html.includes('esm.sh/')) {
  throw new Error('В HTML осталась ссылка на esm.sh.');
}

if (html.includes('./vendor/supabase.js')) {
  throw new Error('В HTML осталось старое подключение Supabase.');
}

fs.writeFileSync('../dist/index.html', html);

console.log('Готово: приложение и Supabase встроены в dist/index.html.');
console.log('Размер HTML:', Buffer.byteLength(html, 'utf8'), 'байт.');
JS
