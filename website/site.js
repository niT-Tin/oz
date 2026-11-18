/* A buildless, progressively enhanced page. No visitor API calls or analytics. */
(() => {
  'use strict';

  const nodes = [...document.querySelectorAll('[data-i18n]')];
  const originalText = (node) => [...node.childNodes].map((child) => child.nodeName === 'BR' ? '\n' : child.textContent).join('');
  const en = Object.fromEntries(nodes.map((node) => [node.dataset.i18n, originalText(node)]));
  Object.assign(en, {
    'shot.completion': 'ZLS shows the ArrayList signature and documentation beside the selected completion.',
    'shot.agent': 'The Codex thread has the current file as context. A question is in the prompt, ready to send.',
    'agent.kimi': 'Install and sign in to Kimi Code first. The preset starts kimi acp.',
    'agent.deepseek': 'Prepare a DeepSeek Harness checkout and its dependencies. Substitute its path for the example. The preset runs pnpm --silent dsh --profile acp.',
    'copied': 'Command copied.',
    'copy.failed': 'Command selected. Copy it with your keyboard.',
    'download.selected': 'Download',
  });
  const zh = {
    'skip': '跳到正文',
    'nav.inside': '编辑器',
    'nav.agents': 'Agent',
    'nav.download': '安装',
    'hero.first': '在终端里',
    'hero.last': '写代码。',
    'hero.body': 'oz 是用 Zig 编写的模态编辑器。用 Vim 键位编辑，用 LSP 查定义，也可以在代码旁打开自己的 coding agent。',
    'hero.download': '下载 oz',
    'tour.title': '编辑器实拍',
    'showcase.editor': '文件树',
    'showcase.completion': '代码补全',
    'showcase.agent': 'Agent 面板',
    'showcase.enlarge': '查看大图',
    'shot.editor': '展开项目目录，编辑 oz 自己的图表渲染代码。',
    'shot.completion': '选中 ArrayList，右侧立即显示 ZLS 返回的签名和文档。',
    'shot.agent': 'Codex 线程已关联当前文件，输入框里的问题尚未发送。',
    'download.title': '安装 oz',
    'download.intro': '选择系统和架构，解压下载的文件，即可打开代码。',
    'download.platform': '操作系统和处理器架构',
    'download.choose': '选择平台',
    'download.browse': '全部下载',
    'download.selected': '下载',
    'download.source': '从源码构建',
    'download.zig': '使用发布版本构建时采用的 Zig 0.17.0。',
    'agents.title': '接入 Agent',
    'agents.intro': '选择 ACP 预设启动 oz，按 Space a 打开面板。',
    'agent.codex': '先安装并登录 Codex。ACP 适配器通过 npx 启动。',
    'agent.kimi': '先安装并登录 Kimi Code。此预设启动 kimi acp。',
    'agent.deepseek': '先准备好 DeepSeek Harness 源码和依赖，将示例路径换成你的目录。此预设运行 pnpm --silent dsh --profile acp。',
    'footer.issues': '反馈问题',
    'footer.releases': '历史版本',
    'copy': '复制',
    'copied': '命令已复制。',
    'copy.failed': '已选中命令，请用键盘复制。',
    'dialog.title': '编辑器截图',
    'dialog.close': '关闭',
  };

  let savedLanguage;
  try { savedLanguage = localStorage.getItem('oz-site-language'); } catch { /* storage is optional */ }
  const requestedLanguage = new URLSearchParams(location.search).get('lang');
  const supported = (value) => value === 'en' || value === 'zh';
  let language = supported(requestedLanguage) ? requestedLanguage : supported(savedLanguage) ? savedLanguage : navigator.language.startsWith('zh') ? 'zh' : 'en';
  let activeShot = 'editor';
  let activeAgent = 'codex';
  let feedbackTimer;
  const t = (key) => (language === 'zh' ? zh[key] : en[key]) ?? en[key] ?? key;
  const setText = (node, text) => node.replaceChildren(...text.split('\n').flatMap((line, index) => index ? [document.createElement('br'), document.createTextNode(line)] : [document.createTextNode(line)]));

  const shots = {
    editor: { en: 'oz editing Zig code, with syntax highlighting, a file navigator and status bar.', zh: 'oz 编辑 Zig 代码，展示语法高亮、文件导航器和状态栏。' },
    completion: { en: 'oz LSP completion with colored kinds, signatures and adjacent documentation.', zh: 'oz LSP 补全，展示彩色类型图标、签名和紧邻的文档窗口。' },
    agent: { en: 'oz with its Agent panel beside the editor, before a prompt is sent.', zh: 'oz 在编辑器旁打开 Agent 面板，尚未发送提示词。' },
  };
  const commands = {
    codex: 'OZ_ACP_AGENT=codex oz src/main.zig',
    kimi: 'OZ_ACP_AGENT=kimi oz src/main.zig',
    deepseek: 'OZ_ACP_AGENT=deepseek \\\nOZ_ACP_CWD=/path/to/deepseek-harness \\\noz src/main.zig',
  };
  const screenshot = document.getElementById('screenshot');
  const dialog = document.getElementById('screenshot-dialog');
  const zoom = document.getElementById('zoom-image');
  const opener = document.querySelector('[data-open-screenshot]');
  const platform = document.getElementById('platform');
  const download = document.getElementById('download-link');
  const platforms = new Set(['aarch64-macos', 'x86_64-macos', 'x86_64-linux', 'aarch64-linux']);

  function showShot(key) {
    if (!Object.hasOwn(shots, key)) return;
    activeShot = key;
    for (const button of document.querySelectorAll('[data-shot]')) {
      const selected = button.dataset.shot === key;
      button.setAttribute('aria-selected', String(selected));
      button.tabIndex = selected ? 0 : -1;
    }
    document.getElementById('screenshot-panel').setAttribute('aria-labelledby', `shot-${key}`);
    screenshot.setAttribute('src', `./assets/${key}.png`);
    screenshot.alt = shots[key][language];
    zoom.src = screenshot.src;
    zoom.alt = screenshot.alt;
    opener.setAttribute('aria-label', `${t('showcase.enlarge')}: ${t(`showcase.${key}`)}`);
    const caption = document.getElementById('screenshot-caption');
    caption.dataset.i18n = `shot.${key}`;
    setText(caption, t(`shot.${key}`));
  }

  function showAgent(key) {
    if (!Object.hasOwn(commands, key)) return;
    activeAgent = key;
    for (const button of document.querySelectorAll('[data-agent]')) {
      const selected = button.dataset.agent === key;
      button.setAttribute('aria-selected', String(selected));
      button.tabIndex = selected ? 0 : -1;
    }
    document.getElementById('agent-code-panel').setAttribute('aria-labelledby', `preset-${key}`);
    document.getElementById('agent-command').textContent = commands[key];
    const prerequisite = document.getElementById('agent-prerequisite');
    prerequisite.dataset.i18n = `agent.${key}`;
    setText(prerequisite, t(`agent.${key}`));
  }

  function updateDownload() {
    const selected = platform.value;
    if (!platforms.has(selected)) {
      download.href = 'https://github.com/niT-Tin/oz/releases/latest';
      document.getElementById('download-label').textContent = t('download.browse');
      download.removeAttribute('aria-label');
      return;
    }
    download.href = `https://github.com/niT-Tin/oz/releases/latest/download/oz-${selected}.tar.gz`;
    document.getElementById('download-label').textContent = `${t('download.selected')} .tar.gz`;
    download.setAttribute('aria-label', `${t('download.selected')} ${platform.selectedOptions[0].textContent}`);
  }

  function setLanguage(value, save = false) {
    language = value;
    document.documentElement.lang = value === 'zh' ? 'zh-CN' : 'en';
    for (const node of nodes) setText(node, t(node.dataset.i18n));
    const languageSwitch = document.querySelector('[data-language-switch]');
    languageSwitch.textContent = value === 'zh' ? 'English' : '中文';
    languageSwitch.lang = value === 'zh' ? 'en' : 'zh-CN';
    const url = new URL(location.href);
    url.searchParams.set('lang', value === 'zh' ? 'en' : 'zh');
    languageSwitch.href = `${url.pathname}${url.search}${url.hash}`;
    if (save) {
      try { localStorage.setItem('oz-site-language', value); } catch { /* storage is optional */ }
      url.searchParams.set('lang', value);
      history.replaceState(null, '', `${url.pathname}${url.search}${url.hash}`);
    }
    document.title = value === 'zh' ? 'oz — 终端文本编辑器' : 'oz — terminal text editor';
    showShot(activeShot);
    showAgent(activeAgent);
    updateDownload();
  }

  document.querySelector('[data-language-switch]').addEventListener('click', (event) => {
    event.preventDefault();
    setLanguage(language === 'zh' ? 'en' : 'zh', true);
  });
  platform.addEventListener('change', updateDownload);
  for (const button of document.querySelectorAll('[data-shot]')) button.addEventListener('click', () => showShot(button.dataset.shot));
  for (const button of document.querySelectorAll('[data-agent]')) button.addEventListener('click', () => showAgent(button.dataset.agent));
  const shotTabs = document.querySelector('.shot-tabs');
  const compact = matchMedia('(max-width: 650px)');
  const orientTabs = () => shotTabs.setAttribute('aria-orientation', compact.matches ? 'horizontal' : 'vertical');
  orientTabs();
  compact.addEventListener('change', orientTabs);
  for (const group of document.querySelectorAll('[role="tablist"]')) {
    group.addEventListener('keydown', (event) => {
      const tabs = [...group.querySelectorAll('[role="tab"]')];
      let index = tabs.indexOf(document.activeElement);
      if (index < 0) return;
      const vertical = group.getAttribute('aria-orientation') === 'vertical';
      if (event.key === 'ArrowRight' || (vertical && event.key === 'ArrowDown')) index = (index + 1) % tabs.length;
      else if (event.key === 'ArrowLeft' || (vertical && event.key === 'ArrowUp')) index = (index + tabs.length - 1) % tabs.length;
      else if (event.key === 'Home') index = 0;
      else if (event.key === 'End') index = tabs.length - 1;
      else return;
      event.preventDefault();
      tabs[index].focus();
      tabs[index].click();
    });
  }

  opener.addEventListener('click', () => dialog.showModal());
  dialog.querySelector('.dialog-close').addEventListener('click', () => dialog.close());
  dialog.addEventListener('click', (event) => { if (event.target === dialog) dialog.close(); });
  dialog.addEventListener('close', () => opener.focus({ preventScroll: true }));
  for (const button of document.querySelectorAll('[data-copy]')) {
    button.addEventListener('click', async () => {
      const node = document.getElementById(button.dataset.copy);
      let message;
      try {
        if (!navigator.clipboard) throw new Error('Clipboard unavailable');
        await navigator.clipboard.writeText(node.textContent);
        message = t('copied');
      } catch {
        const range = document.createRange();
        range.selectNodeContents(node);
        const selection = window.getSelection();
        selection.removeAllRanges();
        selection.addRange(range);
        message = t('copy.failed');
      }
      const feedback = document.getElementById('feedback');
      feedback.textContent = message;
      feedback.classList.add('visible');
      clearTimeout(feedbackTimer);
      feedbackTimer = setTimeout(() => feedback.classList.remove('visible'), 3500);
    });
  }
  setLanguage(language);
})();
