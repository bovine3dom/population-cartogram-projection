import {writeFile, mkdir} from 'node:fs/promises';
import {resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
const [repo, output, origin='http://127.0.0.1:1983'] = process.argv.slice(2);
if (!repo || !output) throw new Error('Usage: review_h3_mon.mjs H3_MON_REPO OUTPUT [ORIGIN]');
const {chromium} = await import(pathToFileURL(resolve(repo,'node_modules/playwright/index.mjs')));
const out=resolve(output);await mkdir(out,{recursive:true});
const browser=await chromium.launch({headless:true,executablePath:process.env.CHROMIUM_PATH || '/usr/bin/chromium',args:['--use-angle=swiftshader','--enable-unsafe-swiftshader','--disable-dev-shm-usage']});
try {
 const page=await browser.newPage({viewport:{width:2000,height:1200},deviceScaleFactor:1,reducedMotion:'reduce'});
 const errors=[],requests=[];page.on('pageerror',e=>errors.push(String(e)));page.on('requestfailed',r=>requests.push([r.url(),r.failure()]));
 await page.route('**/toner_ofm_moderatlist.json',route=>route.fulfill({json:{version:8,sources:{},layers:[{id:'background',type:'background',paint:{'background-color':'#e7edf1'}}]}}));
 const url=origin+'/?data=planet-auto-55000-h3-5-islands/population_density_hilo.arrow&cartogram=planet-auto-55000-h3-5-islands/cartogram_weights_auto_55000_h3_5_hilo.arrow#x=0&y=15&z=-1';
 await page.goto(url);await page.waitForFunction(()=>document.body.classList.contains('load-complete')&&document.body.classList.contains('cartogram-ready'),{},{timeout:240000});
 await page.waitForTimeout(2500);
 await page.locator('#rightExpand').click();await page.waitForTimeout(1500);
 await page.mouse.move(1000,600);await page.mouse.wheel(0,400);await page.waitForTimeout(2500);
 await page.mouse.move(600,250);await page.mouse.down();await page.mouse.move(950,250,{steps:15});await page.mouse.up();await page.waitForTimeout(2000);
 await page.screenshot({path:out+'/h3-mon-world.png'});
 for (const [name,x,y,delta] of [['japan',930,465,-1400],['indonesia',800,690,-1000],['europe',400,455,-1000]]) {
  await page.goto('about:blank');await page.goto(url);await page.waitForFunction(()=>document.body.classList.contains('load-complete')&&document.body.classList.contains('cartogram-ready'),{},{timeout:240000});
  await page.waitForTimeout(1500);await page.mouse.move(x,y);await page.mouse.wheel(0,delta);await page.waitForTimeout(2000);
  await page.mouse.move(500,500);await page.mouse.down();await page.mouse.move(1000-x,1100-y,{steps:15});await page.mouse.up();await page.waitForTimeout(3000);
  await page.screenshot({path:out+'/h3-mon-'+name+'.png'});
 }
 await writeFile(out+'/browser-checks.json',JSON.stringify({url,errors,failedRequests:requests,basemap:'Neutral local style; actual H3-MON app and density overlay',bodyClass:await page.locator('body').getAttribute('class')},null,2));
 if(errors.length || requests.length)throw new Error('Browser errors or failed requests; see browser-checks.json');
}finally{await browser.close();}
