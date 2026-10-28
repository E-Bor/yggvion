import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync(new URL('../server/internal/httpapi/public/calendar.js', import.meta.url), 'utf8');
const html = readFileSync(new URL('../server/internal/httpapi/public/index.html', import.meta.url), 'utf8');
// Exercise the actual localization bootstrap against the shipped static markup.
// Stop before calendar/network initialization; guest data is never translated.
const bootstrap = source.slice(0, source.indexOf('  const $ =')) +
  '\n globalThis.result = {t, language, messages};\n})();';

for (const language of ['ru', 'en', 'es', 'de', 'zh', 'hi']) {
  test(`public calendar translates initial markup and messages: ${language}`, () => {
    const nodes = html.split('<body>')[1].split('</body>')[0]
      .split(/<[^>]*>/).filter((text) => /[А-Яа-яЁё]/.test(text))
      .map((textContent) => ({ textContent }));
    const attributes = [...html.matchAll(/(aria-label|placeholder)="([^"]+)"/g)]
      .map(([, name, value]) => ({
        value,
        getAttribute(key) { return key === name ? this.value : null; },
        setAttribute(key, text) { assert.equal(key, name); this.value = text; },
      }));
    const document = {
      body: {}, documentElement: {}, title: '',
      createTreeWalker() {
        let i = 0;
        return { nextNode() { this.currentNode = nodes[i++]; return !!this.currentNode; } };
      },
      querySelectorAll() { return attributes; },
    };
    const context = { document, navigator: { languages: [language + '-XX'] }, NodeFilter: { SHOW_TEXT: 4 } };
    vm.runInNewContext(bootstrap, context);
    assert.equal(document.documentElement.lang, language);
    for (const [key, translations] of Object.entries(context.result.messages)) {
      assert.equal(translations.length, 5, key);
      const parameters = (text) => [...text.matchAll(/\{\d+\}/g)].map((m) => m[0]).sort();
      for (const text of translations) {
        assert.ok(text.length, key);
        assert.deepEqual(parameters(text), parameters(key), key);
      }
    }
    if (language !== 'ru') {
      for (const node of nodes) assert.doesNotMatch(node.textContent, /[А-Яа-яЁё]/);
      for (const attribute of attributes) assert.doesNotMatch(attribute.value, /[А-Яа-яЁё]/);
      assert.doesNotMatch(document.title, /[А-Яа-яЁё]/);
    }
    assert.ok(context.result.t('Ваш часовой пояс · {0}', '<img> {0}').endsWith('<img> {0}'));
  });
}

test('every dynamic system message has a translation', () => {
  const dictionary = JSON.parse(source.slice(source.indexOf('  const messages = ') + 19, source.indexOf('\n  const t =')).trim().replace(/;$/, ''));
  for (const [, message] of source.matchAll(/\bt\("([^"\n]+)"/g)) {
    assert.ok(Object.hasOwn(dictionary, message), message);
  }
});
