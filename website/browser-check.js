/* Run this function in Expect's Playwright context; see README.md. */
async ({ page, context }) => {
  const base = new URL('./', page.url()).href;
  const results = [];
  const failures = [];
  const check = (ok, name) => { if (!ok) throw new Error(name); results.push(name); };
  const noOverflow = () => page.evaluate(() => document.documentElement.scrollWidth <= innerWidth);
  const visit = async (suffix = '?lang=en') => {
    await page.goto(base + suffix, { waitUntil: 'networkidle' });
    await page.evaluate(() => document.fonts.ready);
  };
  page.on('pageerror', (error) => failures.push(error.message));
  for (const width of [320, 390, 768, 1440]) {
    await page.setViewportSize({ width, height: 900 });
    for (const lang of ['en', 'zh']) {
      await visit(`?lang=${lang}`);
      check(await noOverflow(), `No page overflow at ${width}px / ${lang}`);
      check(await page.locator('html').getAttribute('lang') === (lang === 'zh' ? 'zh-CN' : 'en'), `Locale at ${width}px / ${lang}`);
      check(await page.locator('#screenshot').evaluate((img) => img.complete && img.naturalWidth === 1680), `Actual screenshot loads at ${width}px / ${lang}`);
      await page.evaluate(() => { document.documentElement.style.fontSize = '200%'; });
      check(await noOverflow(), `200% text stays inside the page at ${width}px / ${lang}`);
      await page.evaluate(() => { document.documentElement.style.removeProperty('font-size'); });
    }
  }
  await visit();
  await page.locator('.skip-link').focus();
  check(await page.locator('.skip-link').evaluate((node) => node.getBoundingClientRect().top >= 0), 'Skip link becomes visible on keyboard focus');
  await page.locator('#shot-completion').click();
  check((await page.locator('#screenshot').getAttribute('src')).endsWith('completion.png'), 'Completion tab shows its actual image');
  await page.locator('#shot-completion').press('End');
  check(await page.locator('#shot-agent').getAttribute('aria-selected') === 'true', 'Screenshot tabs support End');
  await page.locator('#shot-agent').press('Home');
  await page.locator('#shot-editor').press('ArrowLeft');
  check(await page.locator('#shot-agent').getAttribute('aria-selected') === 'true', 'Screenshot tabs wrap with ArrowLeft');
  await page.locator('[data-language-switch]').click();
  check(await page.locator('#shot-agent').getAttribute('aria-selected') === 'true', 'Locale switch preserves selected screenshot');
  check((await page.locator('#screenshot-caption').innerText()).includes('尚未发送提示词'), 'Agent screenshot description remains honest and translated');

  await page.locator('#preset-codex').focus();
  await page.locator('#preset-codex').press('End');
  check((await page.locator('#agent-command').innerText()).includes('OZ_ACP_CWD=/path/to/deepseek-harness'), 'DeepSeek command includes required harness path');
  await page.locator('#preset-kimi').click();
  check(await page.locator('#agent-command').innerText() === 'OZ_ACP_AGENT=kimi oz src/main.zig', 'Kimi command does not contain stale Codex/DeepSeek settings');
  await page.locator('[data-language-switch]').click();
  check(await page.locator('#preset-kimi').getAttribute('aria-selected') === 'true', 'Locale switch preserves agent preset');
  for (const platform of ['aarch64-macos', 'x86_64-macos', 'x86_64-linux', 'aarch64-linux']) {
    await page.locator('#platform').selectOption(platform);
    check((await page.locator('#download-link').getAttribute('href')).endsWith(`/oz-${platform}.tar.gz`), `Correct released archive for ${platform}`);
  }
  await page.locator('#platform').selectOption('');
  check((await page.locator('#download-link').getAttribute('href')).endsWith('/releases/latest'), 'Cleared platform returns to release browser');
  check(await page.locator('#download-link').getAttribute('aria-label') === null, 'Cleared platform has no stale architecture label');

  await context.grantPermissions(['clipboard-read', 'clipboard-write']);
  await page.locator('[data-copy="agent-command"]').click();
  check(await page.evaluate(() => navigator.clipboard.readText()) === 'OZ_ACP_AGENT=kimi oz src/main.zig', 'Copy writes the selected agent command to the actual clipboard');
  await page.evaluate(() => Object.defineProperty(navigator.clipboard, 'writeText', { configurable: true, value: async () => { throw new Error('denied'); } }));
  await page.locator('[data-copy="run-command"]').dblclick();
  check((await page.locator('#feedback').innerText()).includes('selected'), 'Denied clipboard shows a truthful manual-copy fallback');
  check(await page.evaluate(() => getSelection().toString()) === './oz src/main.zig', 'Denied clipboard selects the exact command');

  await page.locator('[data-open-screenshot]').click();
  check(await page.locator('#screenshot-dialog').evaluate((d) => d.open), 'Screenshot opens in a real modal dialog');
  await page.keyboard.press('Tab');
  check(await page.evaluate(() => document.querySelector('dialog').contains(document.activeElement)), 'Modal retains keyboard focus');
  await page.keyboard.press('Escape');
  check(await page.locator('[data-open-screenshot]').evaluate((n) => n === document.activeElement), 'Escape closes modal and returns focus to its trigger');
  check(await page.locator('#screenshot-dialog').evaluate((d) => !d.open), 'Modal is closed after Escape');
  await page.setViewportSize({ width: 320, height: 700 });
  await page.locator('.source-build summary').click();
  check(await noOverflow(), 'Expanded source commands wrap at 320px');
  check((await page.locator('#source-command').innerText()).includes('zig build -Doptimize=ReleaseFast -Dstrip'), 'Source build commands retain the actual repository workflow');

  await visit('?lang=zh&utm_source=test#download');
  await page.locator('[data-language-switch]').click();
  check(page.url().includes('lang=en') && page.url().includes('utm_source=test') && page.url().endsWith('#download'), 'Locale switch preserves tracking query and deep link');
  await page.reload({ waitUntil: 'networkidle' });
  check(await page.locator('html').getAttribute('lang') === 'en', 'Explicit locale survives reload');
  await visit('?lang=invalid');
  check(['en', 'zh-CN'].includes(await page.locator('html').getAttribute('lang')), 'Invalid locale falls back without breaking the page');
  const browser = context.browser();
  const blocked = await browser.newContext({ viewport: { width: 390, height: 844 } });
  try {
    await blocked.addInitScript(() => Object.defineProperty(window, 'localStorage', { get() { throw new Error('blocked'); } }));
    const other = await blocked.newPage();
    await other.goto(base + '?lang=zh', { waitUntil: 'networkidle' });
    await other.locator('[data-language-switch]').click();
    check(await other.locator('html').getAttribute('lang') === 'en', 'Locale switching works when storage is blocked');
  } finally { await blocked.close(); }
  const plain = await browser.newContext({ javaScriptEnabled: false });
  try {
    const other = await plain.newPage();
    await other.goto(base, { waitUntil: 'networkidle' });
    check(await other.locator('h1').isVisible(), 'Core introduction is readable without JavaScript');
    check((await other.locator('#download-link').getAttribute('href')).endsWith('/releases/latest'), 'Downloads remain usable without JavaScript');
    check(await other.locator('noscript a').count() === 4, 'No-JavaScript alternative exposes screenshots and Chinese introduction');
  } finally { await plain.close(); }
  check(failures.length === 0, `No uncaught page errors: ${failures.join(', ')}`);
  await page.setViewportSize({ width: 1440, height: 1000 });
  await visit('?lang=zh');
  return { passed: results.length, checks: results };
}
