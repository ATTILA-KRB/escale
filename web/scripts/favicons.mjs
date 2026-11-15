// Génère les icônes du site à partir de public/favicon.svg (seule source) : `node scripts/favicons.mjs`.
// favicon.ico (16/32/48, PNG embarqués), apple-touch-icon (fond plein : iOS noircit la transparence)
// et icônes du manifeste (192/512).
import { readFile, writeFile } from 'node:fs/promises';
import sharp from 'sharp';

const pub = new URL('../public/', import.meta.url);
const svg = await readFile(new URL('favicon.svg', pub), 'utf8');
// Variante pleine page : le carré arrondi couvre tout le cadre, iOS et Android appliquent leur propre masque.
const full = svg.replace(/<rect x="64" y="64" width="896" height="896" rx="200"/, '<rect width="1024" height="1024"');
if (full === svg) throw new Error('favicon.svg : carré de fond introuvable, mettre à jour le motif');

const png = (src, size) => sharp(Buffer.from(src), { density: 300 }).resize(size, size).png().toBuffer();

// ICO : en-tête + répertoire + images PNG (accepté par tous les navigateurs actuels).
async function ico(sizes) {
  const imgs = await Promise.all(sizes.map((s) => png(svg, s)));
  const head = Buffer.alloc(6 + 16 * imgs.length);
  head.writeUInt16LE(0, 0);
  head.writeUInt16LE(1, 2);
  head.writeUInt16LE(imgs.length, 4);
  let offset = head.length;
  imgs.forEach((img, i) => {
    const e = 6 + 16 * i;
    head.writeUInt8(sizes[i] % 256, e);
    head.writeUInt8(sizes[i] % 256, e + 1);
    head.writeUInt16LE(1, e + 4);
    head.writeUInt16LE(32, e + 6);
    head.writeUInt32LE(img.length, e + 8);
    head.writeUInt32LE(offset, e + 12);
    offset += img.length;
  });
  return Buffer.concat([head, ...imgs]);
}

const out = {
  'favicon.ico': await ico([16, 32, 48]),
  'apple-touch-icon.png': await png(full, 180),
  'icon-192.png': await png(full, 192),
  'icon-512.png': await png(full, 512),
};
for (const [name, buf] of Object.entries(out)) {
  await writeFile(new URL(name, pub), buf);
  console.log(name, buf.length);
}
