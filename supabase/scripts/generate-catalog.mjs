import { readFile,writeFile } from 'node:fs/promises';
const films=JSON.parse(await readFile(new URL('../../App/Resources/films.json',import.meta.url),'utf8'));
const catalog=Object.fromEntries(films.map(f=>[f.id,{fsk:f.fsk??99,forLittleKids:f.fsk===0&&(f.genres.includes('Animation')||f.genres.includes('Familie'))}]));
await writeFile(new URL('../functions/film-device/catalog.mjs',import.meta.url),'// Generated from the bundled catalog. Run node supabase/scripts/generate-catalog.mjs after safety metadata changes.\nexport const catalog = '+JSON.stringify(catalog)+';\n');
console.log(`Generated trusted safety metadata for ${films.length} titles`);
