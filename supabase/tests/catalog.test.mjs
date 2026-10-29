import test from 'node:test';import assert from 'node:assert/strict';import {readFile} from 'node:fs/promises';
import {catalog} from '../functions/film-device/catalog.mjs';
test('trusted backend FSK and little-kid rules match the shipped Swift catalog',async()=>{
 const films=JSON.parse(await readFile(new URL('../../App/Resources/films.json',import.meta.url),'utf8'));
 const expected=Object.fromEntries(films.map(f=>[f.id,{fsk:f.fsk??99,forLittleKids:f.fsk===0&&(f.genres.includes('Animation')||f.genres.includes('Familie'))}]));
 assert.deepEqual(catalog,expected);
});
