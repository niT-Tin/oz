/* A buildless, progressively enhanced page. No visitor API calls or analytics. */
(() => {
  'use strict';

  const nodes = [...document.querySelectorAll('[data-i18n]')];
  const originalText = (node) => [...node.childNodes].map((child) => child.nodeName === 'BR' ? '\n' : child.textContent).join('');
  const en = Object.fromEntries(nodes.map((node) => [node.dataset.i18n, originalText(node)]));
  Object.assign(en, {
    'shot.editor': 'Real code. Real editor. A little room to think.',
    'shot.completion': 'Colored kinds, signatures and documentation, next to your completion.',
    'shot.agent': 'The Agent panel beside your code, before a prompt is sent.',
    'agent.codex': 'Install and authenticate Codex first. This preset uses the Codex ACP adapter (downloaded on first use) and requires Node.js / npx.',
    'agent.kimi': 'Install and authenticate Kimi Code first. This preset starts kimi acp and uses your existing harness configuration.',
    'agent.deepseek': 'Prepare your DeepSeek Harness checkout and its dependencies first. Replace the example path with your checkout; this preset runs pnpm --silent dsh --profile acp.',
    'copied': 'Command copied.',
    'copy.failed': 'The command is selected. Copy it with your keyboard.',
    'download.selected': 'Download',
  });
  const zh = {
    'skip': '跳到正文',
    'nav.inside': '了解 oz', 'nav.agents': '接入 Agent', 'nav.download': '开始使用',
    'hero.eyebrow': '用 Zig 编写的终端文本编辑器',
    'hero.line1': '代码在眼前。', 'hero.line2': 'Agent 在手边。',
    'hero.description': 'Vim 风格的编辑，恰到好处的代码辅助，以及你惯用的 coding agent。一天的工作，都在终端里。',
    'hero.cta': '让终端成为工作台', 'hero.platforms': 'Linux 与 macOS',
    'showcase.label': '看得更近一些', 'showcase.editor': '编辑器',
    'showcase.completion': '代码辅助', 'showcase.agent': 'Agent 面板',
    'showcase.enlarge': '放大查看', 'showcase.docs': '阅读使用文档',
    'shot.editor': '真实代码，真实编辑器。留一点空间，认真思考。',
    'shot.completion': '彩色类型图标、函数签名与详细文档，紧贴补全列表。',
    'shot.agent': '代码旁的 Agent 面板。截图尚未发送提示词。',
    'inside.eyebrow': '01 / 日常编辑，该有的都有',
    'inside.title': '熟悉的手感。\n完整的工作台。',
    'inside.intro': '常用的能力，伸手就到。留出空间，专心写代码。',
    'feature.edit.title': '沿用你的肌肉记忆。',
    'feature.edit.body': '移动、文本对象、Visual 块选、宏与分屏。用双手熟悉的方式，继续编辑。',
    'feature.code.title': '多理解一点你的代码。',
    'feature.code.body': 'LSP 补全、悬浮文档、签名提示、诊断下划线，以及 tree-sitter 语法高亮。',
    'feature.code.note': '读一读文档',
    'feature.project.title': '让项目里的事，留在一起。',
    'feature.project.body': '文件导航、模糊搜索、项目全文搜索、独立工作区、Git hunk，还有随时打开的内嵌终端。',
    'feature.project.note': '找到下一个文件',
    'agents.eyebrow': '02 / 带上你惯用的 Agent',
    'agents.line1': '你的 Agent。', 'agents.line2': '你的工作方式。',
    'agents.body': '通过 ACP 接入你已有的 harness，沿用它的模型和工具。在代码旁，查看对话和工具执行活动。',
    'agents.docs': '阅读配置说明', 'agents.command': '用已有的 harness 启动 oz',
    'agents.key': '然后按下',
    'agent.codex': '先安装并登录 Codex。此预设通过 Codex ACP 适配器连接，首次使用可能下载适配器，需要 Node.js / npx。',
    'agent.kimi': '先安装并登录 Kimi Code。此预设运行 kimi acp，沿用你已有的 harness 配置。',
    'agent.deepseek': '先准备好 DeepSeek Harness 源码及依赖，将示例路径换成你的目录。此预设运行 pnpm --silent dsh --profile acp。',
    'agents.custom': '也支持自定义 ACP 命令和 OpenAI 兼容 API。',
    'download.eyebrow': '03 / 从这里开始',
    'download.title': '你的终端。\n新的编辑器。',
    'download.intro': '下载对应平台的构建，解压，再打开一个文件。无需安装 Zig。',
    'download.platform': '选择你的平台', 'download.choose': '选择平台与架构',
    'download.browse': '查看全部下载', 'download.selected': '下载',
    'download.run': '解压后，打开一个文件',
    'download.note': '建议使用真彩色终端和 Nerd Font 显示图标。代码辅助需要安装对应语言服务器；项目全文搜索需要 ripgrep。',
    'download.releases': '更新日志与校验文件', 'download.license': 'MIT 开源协议',
    'download.source': '更喜欢从源码构建？', 'download.zig': 'CI 使用 Zig 0.17.0。',
    'closing': '一个为日常工作打磨的个人项目。\n持续生长，始终开源。',
    'closing.contribute': '一起决定下一步', 'footer': '用 Zig 构建，为日常使用。', 'footer.issues': '反馈问题',
    'copy': '复制', 'copied': '命令已复制。', 'copy.failed': '已选中命令，请使用键盘复制。',
    'dialog.title': '近距离看看 oz', 'dialog.close': '关闭',
    'dialog.hint': '滚动查看完整截图，按 Esc 关闭。',
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
    document.title = value === 'zh' ? 'oz — 代码在眼前，Agent 在手边。' : 'oz — Code in focus. Agents in reach.';
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
  for (const group of document.querySelectorAll('[role="tablist"]')) {
    group.addEventListener('keydown', (event) => {
      const tabs = [...group.querySelectorAll('[role="tab"]')];
      let index = tabs.indexOf(document.activeElement);
      if (index < 0) return;
      if (event.key === 'ArrowRight') index = (index + 1) % tabs.length;
      else if (event.key === 'ArrowLeft') index = (index + tabs.length - 1) % tabs.length;
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
