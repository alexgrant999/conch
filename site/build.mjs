// Copies the static files into dist, makes WebP copies of every PNG in media/ at the widths the page asks for,
// and writes each screenshot's real pixel size into its <img> so swapping a screenshot never shifts the layout.
// Tailwind runs after this (see package.json) and writes dist/styles.css.
import { cp, mkdir, readFile, readdir, rm, writeFile } from 'node:fs/promises'
import sharp from 'sharp'

const OUT = 'dist'
const WEBP_WIDTHS = [1400, 2800]
const OG_BACKGROUND = '#17171a'

await rm(OUT, { recursive: true, force: true })
await mkdir(`${OUT}/media`, { recursive: true })
await cp('icons', `${OUT}/icons`, { recursive: true })
for (const file of ['robots.txt', 'sitemap.xml']) await cp(file, `${OUT}/${file}`)

const sizes = {}
for (const file of await readdir('media')) {
  if (file.startsWith('.')) continue
  await cp(`media/${file}`, `${OUT}/media/${file}`)
  if (!file.endsWith('.png')) continue
  const { width, height } = await sharp(`media/${file}`).metadata()
  sizes[file] = { width, height }
  for (const target of WEBP_WIDTHS) {
    await sharp(`media/${file}`)
      .resize({ width: target, withoutEnlargement: true })
      .webp({ quality: 86 })
      .toFile(`${OUT}/media/${file.slice(0, -4)}-${target}.webp`)
  }
}

// Link previews get a flat 1200 x 630 card: the transparent hero on the page's dark canvas colour.
await sharp('media/hero.png')
  .resize({ width: 1200, height: 630, fit: 'contain', background: OG_BACKGROUND })
  .flatten({ background: OG_BACKGROUND })
  .png()
  .toFile(`${OUT}/media/og.png`)

const html = (await readFile('index.html', 'utf8')).replace(
  /<img\b[^>]*\bsrc="\.\/media\/([^"]+\.png)"[^>]*>/g,
  (tag, file) => {
    const size = sizes[file]
    if (!size) throw new Error(`index.html shows media/${file}, but site/media has no such file`)
    return tag.replace(/\bwidth="\d+"/, `width="${size.width}"`).replace(/\bheight="\d+"/, `height="${size.height}"`)
  },
)
await writeFile(`${OUT}/index.html`, html)
