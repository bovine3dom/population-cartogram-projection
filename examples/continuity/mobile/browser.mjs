// Isolated headless check. This does not start the H3-MON service.
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {createReadStream} from 'node:fs';
import {mkdir, readFile, stat, writeFile} from 'node:fs/promises';
import {createRequire} from 'node:module';
import {resolve, join} from 'node:path';

assert.equal(process.argv.length, 6, 'usage: browser.mjs H3_MON_ROOT TRANSPORT_ARROW DENSITY_ARROW OUTPUT');
const [appRoot, transport, density, output] = process.argv.slice(2).map(path => resolve(path));
const require = createRequire(join(appRoot, 'package.json'));
const {chromium} = require('playwright');
await mkdir(output, {recursive: true});
const failures = [], warnings = [], requests = [], samples = [], timings = [];
const heapMB = Number(process.env.JS_HEAP_MB || 0);
assert(Number.isSafeInteger(heapMB) && heapMB >= 0, 'JS_HEAP_MB must be a nonnegative integer');
const viewportCycles = Number(process.env.VIEWPORT_CYCLES || 1);
assert(Number.isSafeInteger(viewportCycles) && viewportCycles > 0, 'VIEWPORT_CYCLES must be a positive integer');
const dataPath = process.env.DATA_PATH || 'mobile.arrow';
const metadata = process.env.METADATA_PATH ? JSON.parse(await readFile(process.env.METADATA_PATH, 'utf8'))
    : {cartogram: 'mobile-cartogram_hilo.arrow', trimFactor: 0};
const files = new Map([
    ['/', [join(appRoot, 'www/index.html'), 'text/html']],
    ['/app.js', [join(appRoot, 'www/app.js'), 'text/javascript']],
    ['/app.css', [join(appRoot, 'www/app.css'), 'text/css']],
    [`/data/${dataPath}`, [density, 'application/octet-stream']],
    [`/data/${metadata.cartogram}`, [transport, 'application/octet-stream']],
]);
const json = new Map([
    [`/data/${dataPath.replace(/\.arrow$/, '.json')}`, metadata],
    ['/toner_ofm_moderatlist.json', {version: 8, sources: {}, layers: [
        {id: 'background', type: 'background', paint: {'background-color': '#eeeeee'}},
    ]}],
]);
const server = createServer(async (req, res) => {
    const path = new URL(req.url, 'http://localhost').pathname;
    requests.push(path);
    if (json.has(path)) {
        res.writeHead(200, {'Content-Type': 'application/json'});
        return res.end(JSON.stringify(json.get(path)));
    }
    if (path === '/favicon.ico') { res.writeHead(204); return res.end(); }
    const file = files.get(path);
    if (!file) { failures.push(`Unexpected request: ${path}`); res.writeHead(404); return res.end(); }
    try {
        res.writeHead(200, {'Content-Type': file[1], 'Content-Length': (await stat(file[0])).size,
            'Cache-Control': 'no-store', ...(file[0].endsWith('.gz') ? {'Content-Encoding': 'gzip'} : {})});
        createReadStream(file[0]).pipe(res);
    } catch (error) { failures.push(String(error)); res.destroy(error); }
});
let browser, interval;
try {
    await new Promise(done => server.listen(0, '127.0.0.1', done));
    const origin = `http://127.0.0.1:${server.address().port}`;
    browser = await chromium.launch({headless: true, executablePath: process.env.CHROMIUM_PATH,
        args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--disable-dev-shm-usage',
            ...(heapMB ? [`--js-flags=--max-heap-size=${heapMB}`, '--enable-precise-memory-info'] : [])]});
    const context = await browser.newContext({viewport: {width: 390, height: 844}, deviceScaleFactor: 2,
        reducedMotion: 'reduce', serviceWorkers: 'block'});
    await context.route('**/*', route => new URL(route.request().url()).origin === origin
        ? route.continue() : (failures.push(`External request: ${route.request().url()}`), route.abort()));
    await context.routeWebSocket('**/*', socket => socket.onMessage(message => {
        if (String(message).startsWith('watch:')) socket.send(`watching:${dataPath}`);
    }));
    const page = await context.newPage();
    page.on('pageerror', error => failures.push(String(error)));
    page.on('console', async message => {
        if (message.type() === 'error') {
            const text = message.text();
            // The app's own rendering test excludes this existing legend warning.
            (text === 'Error: <g> attribute transform: Expected transform function, "0".' ? warnings : failures).push(text);
        }
        if (message.text().startsWith('[perf]')) {
            try { timings.push(await Promise.all(message.args().map(arg => arg.jsonValue()))); }
            catch (error) { failures.push(`Console capture: ${error}`); }
        }
    });
    const cdp = await context.newCDPSession(page);
    await cdp.send('Emulation.setCPUThrottlingRate', {rate: Number(process.env.CPU_THROTTLE || 4)});
    const heapLimit = await page.evaluate(() => performance.memory?.jsHeapSizeLimit);
    if (heapMB) assert(heapLimit <= heapMB * 1024 ** 2, 'requested V8 heap limit was not applied');
    const start = performance.now();
    let sampling = false;
    interval = setInterval(async () => {
        if (sampling) return;
        sampling = true;
        try { samples.push({ms: performance.now() - start, ...await cdp.send('Runtime.getHeapUsage')}); }
        catch {} finally { sampling = false; }
    }, 250);
    const query = new URLSearchParams({data: dataPath, perf: '1'});
    if (process.env.H3_PRECISION) query.set('h3precision', process.env.H3_PRECISION);
    await page.goto(`${origin}/?${query}`, {timeout: 180000});
    await page.waitForFunction(() => document.body.classList.contains('load-complete')
        && window.m?.loaded() && window._columnData?.value?.length > 0, null, {timeout: 180000});
    await page.locator('#cartogram canvas').waitFor({state: 'visible', timeout: 180000});
    const loadMs = performance.now() - start;
    const data = await page.evaluate(() => {
        const c = window._columnData;
        const layer = window.m._controls.find(control => control.getCanvas?.()?.id === 'deckgl-overlay')
            ._deck.props.layers.find(layer => layer.id.startsWith('H3HexagonLayer'));
        let finiteValues = 0;
        for (const value of c.value) if (Number.isFinite(value)) finiteValues++;
        return {sourceCells: c.value.length, finiteValues,
            geographicCells: layer.props.data.length};
    });
    assert.equal(data.finiteValues, data.sourceCells, 'nonfinite source value');
    await page.screenshot({path: join(output, 'mobile.png')});
    const resources = await page.evaluate(() => performance.getEntriesByType('resource')
        .filter(entry => entry.name.includes('/data/'))
        .map(({name, encodedBodySize, decodedBodySize, duration}) => ({name, encodedBodySize, decodedBodySize, duration})));
    const beforeGC = await cdp.send('Runtime.getHeapUsage');
    await cdp.send('HeapProfiler.collectGarbage');
    const afterGC = await cdp.send('Runtime.getHeapUsage');
    const pans = [];
    if (process.env.VIEWPORT_STRESS) {
        const initial = await page.evaluate(() => ({center: window.m.getCenter().toArray(), zoom: window.m.getZoom()}));
        const cameras = [{center: [0, 0], zoom: 0}, {center: [179, 0], zoom: 3}, initial];
        for (const camera of Array.from({length: viewportCycles}, () => cameras).flat()) {
            await page.evaluate(camera => { window.m.jumpTo(camera); }, camera);
            await page.waitForFunction(() => {
                const layer = window.m._controls.find(control => control.getCanvas?.()?.id === 'deckgl-overlay')
                    ._deck.props.layers.find(layer => layer.id.startsWith('H3HexagonLayer'));
                return !window.m.isMoving() && layer.state?.geometry?.length === layer.props.data.length;
            });
            await page.evaluate(() => new Promise(done => requestAnimationFrame(() => requestAnimationFrame(done))));
            await cdp.send('HeapProfiler.collectGarbage');
            const counts = await page.evaluate(() => ({sources: window._columnData.value.length,
                visible: window.m._controls.find(control => control.getCanvas?.()?.id === 'deckgl-overlay')
                    ._deck.props.layers.find(layer => layer.id.startsWith('H3HexagonLayer')).props.data.length}));
            assert.equal(counts.sources, data.sourceCells);
            pans.push({camera, ...counts, memory: await cdp.send('Runtime.getHeapUsage')});
        }
    }
    const render = timings.find(row => String(row[0]).startsWith('[perf] cartogram.canvas.render.total:'));
    const labels = timings.find(row => String(row[0]).startsWith('[perf] cartogram.canvas.labels.precompute:'));
    assert(render?.[1]?.rows > 0, 'missing cartogram render');
    data.targetCells = render[1].rows;
    data.targetLabels = labels?.[1]?.labels;
    await writeFile(join(output, 'cells.json'), JSON.stringify(data));
    await writeFile(join(output, 'memory.json'), JSON.stringify({browser: browser.version(), loadMs, heapLimit,
        throttle: Number(process.env.CPU_THROTTLE || 4), h3Precision: process.env.H3_PRECISION || 'default',
        beforeGC, afterGC, pans, samples, timings, resources, failures, warnings, requests}, null, 2));
    console.log(JSON.stringify({loadMs, ...data, beforeGC, afterGC, failures, warnings}));
    if (pans.length) assert.equal(pans.at(-1).visible, data.geographicCells, 'return view changed coverage');
    assert.deepEqual(failures, []);
} finally {
    clearInterval(interval);
    await browser?.close();
    await new Promise(done => server.close(done));
}
