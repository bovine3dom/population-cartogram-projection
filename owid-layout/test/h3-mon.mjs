// Check a local export, or use EXPORT_DIR=- to test a published dataset.
// No H3-MON data files or defaults are changed.
import {mkdir, writeFile} from 'node:fs/promises';
import {resolve, basename} from 'node:path';
import {pathToFileURL} from 'node:url';

const [repo, exported, output, origin = 'http://127.0.0.1:1983', dataset = 'h3-mon', position = 'x=110&y=5&z=3'] = process.argv.slice(2);
if (!repo || !exported || !output) throw new Error('Usage: h3-mon.mjs H3_MON_REPO EXPORT_DIR|- REVIEW_DIR [ORIGIN] [DATASET] [MAP_POSITION]');
const {chromium} = await import(pathToFileURL(resolve(repo, 'node_modules/playwright/index.mjs')));
await mkdir(output, {recursive: true});
const browser = await chromium.launch({headless: true, executablePath: process.env.CHROMIUM_PATH || '/usr/bin/chromium',
    args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--disable-dev-shm-usage']});
try {
    const page = await browser.newPage({viewport: {width: 1600, height: 1000}, reducedMotion: 'reduce'});
    const errors = [], failedRequests = [], served = [];
    page.on('pageerror', error => errors.push(String(error)));
    page.on('requestfailed', request => failedRequests.push({url: request.url(), error: request.failure()}));
    await page.route('**/toner_ofm_moderatlist.json', route => route.fulfill({json: {version: 8, sources: {},
        layers: [{id: 'background', type: 'background', paint: {'background-color': '#e7edf1'}}]}}));
    await page.route(`**/data/${dataset}/*`, async route => {
        const file = basename(new URL(route.request().url()).pathname);
        if (!['population_density_hilo.arrow', 'population_density_hilo.json', 'cartogram_weights_hilo.arrow'].includes(file)) {
            throw new Error(`Unexpected export request: ${file}`);
        }
        served.push(file);
        if (exported === '-') await route.continue();
        else await route.fulfill({path: resolve(exported, file), contentType: file.endsWith('.json') ? 'application/json' : 'application/vnd.apache.arrow.file'});
    });
    const url = `${origin}/?data=${dataset}/population_density_hilo.arrow&cartogram=${dataset}/cartogram_weights_hilo.arrow#${position}`;
    await page.goto(url);
    await page.waitForFunction(() => document.body.classList.contains('load-complete') &&
        document.body.classList.contains('cartogram-ready'), {}, {timeout: 120000});
    await page.locator('#rightExpand').click();
    await page.waitForTimeout(2000);
    await page.screenshot({path: resolve(output, 'h3-mon.png')});
    const report = {url, errors, failedRequests, served, bodyClass: await page.locator('body').getAttribute('class'),
        dataSource: exported === '-' ? 'Published HTTP files' : 'Local file interception',
        basemap: 'Local neutral style; actual H3-MON renderer'};
    await writeFile(resolve(output, 'browser-checks.json'), JSON.stringify(report, null, 2) + '\n');
    if (errors.length || failedRequests.length || new Set(served).size !== 3) throw new Error('Browser check failed; see browser-checks.json');
} finally {
    await browser.close();
}
