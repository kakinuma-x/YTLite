// Bundles the app into one body-only HTML file (for hosts that wrap the page in their own skeleton).
// usage: node tools/build-artifact.mjs <out.html>
import { readFileSync, writeFileSync } from 'node:fs';
const dir = new URL('..', import.meta.url);
const rd = f => readFileSync(new URL(f, dir), 'utf8');
const app = rd('index.html').split('<!--APP-->')[1].split('<!--/APP-->')[0];
const out = `<title>PocketDAW</title>
<meta name="claude:viewport-fit-sides" content="cover">
<style>
${rd('style.css')}
:root { --gutter: 16px; }
</style>
${app}
<script>
${rd('engine.js')}
${rd('app.js')}
</script>
`;
writeFileSync(process.argv[2], out);
console.log('wrote', process.argv[2], out.length, 'bytes');
