/// Page scripts used by the agent operations. They run with `callAsyncJavaScript` in an isolated
/// content world (the page cannot tamper with them); element refs are DOM attributes, so a ref from
/// a snapshot resolves the same element later. Same-document only: iframes and closed shadow roots
/// are not traversed.
enum BrowserScripts {
    /// Shared helpers prepended to every element script. `ref`/`selector` arrive as arguments.
    private static let resolve = """
    const resolveTarget = () => {
      if (typeof ref === 'string' && ref.length) return document.querySelector(`[data-happier-ref="${CSS.escape(ref)}"]`);
      if (typeof selector === 'string' && selector.length) return document.querySelector(selector);
      return null;
    };
    const describe = (el) => ({ tag: el.tagName.toLowerCase(), text: (el.innerText || el.value || '').replace(/\\s+/g, ' ').trim().slice(0, 120) });
    """

    /// Text outline of the page with `[ref=eN]` on interactive elements. Arguments: `maxChars`.
    static let snapshot = """
    document.querySelectorAll('[data-happier-ref]').forEach((el) => el.removeAttribute('data-happier-ref'));
    const interactive = 'a[href],button,input,select,textarea,summary,[role=button],[role=link],[role=checkbox],[role=radio],[role=tab],[role=menuitem],[role=option],[role=switch],[role=combobox],[role=textbox],[role=searchbox],[contenteditable=""],[contenteditable=true],[onclick]';
    const skip = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'SVG', 'HEAD', 'META', 'LINK']);
    const lines = [];
    let length = 0, count = 0, truncated = false;
    const clean = (s) => (s || '').replace(/\\s+/g, ' ').trim();
    const push = (depth, line) => {
      if (truncated) return;
      const text = '  '.repeat(Math.min(depth, 12)) + line;
      if (length + text.length + 1 > maxChars) { truncated = true; return; }
      lines.push(text); length += text.length + 1;
    };
    const hidden = (el) => {
      const style = getComputedStyle(el);
      if (style.display === 'none' || style.visibility === 'hidden' || el.hidden) return true;
      if (el.getAttribute('aria-hidden') === 'true') return true;
      const rect = el.getBoundingClientRect();
      return rect.width === 0 && rect.height === 0 && style.overflow !== 'visible';
    };
    const roleOf = (el) => {
      const explicit = el.getAttribute('role');
      if (explicit) return explicit;
      const tag = el.tagName.toLowerCase();
      if (tag === 'a') return 'link';
      if (tag === 'input') return (el.type || 'text') === 'text' ? 'textbox' : `input[${el.type}]`;
      if (tag === 'textarea') return 'textbox';
      if (tag === 'select') return 'combobox';
      if (el.isContentEditable) return 'textbox';
      return tag;
    };
    const labelOf = (el) => clean(el.getAttribute('aria-label') || el.innerText || el.getAttribute('placeholder')
      || el.getAttribute('title') || el.getAttribute('alt') || el.getAttribute('name') || el.getAttribute('value') || '').slice(0, 140);
    const walk = (node, depth) => {
      if (truncated) return;
      if (node.nodeType === Node.TEXT_NODE) {
        const text = clean(node.textContent);
        if (text) push(depth, text.slice(0, 400));
        return;
      }
      if (node.nodeType !== Node.ELEMENT_NODE) return;
      const el = node;
      if (skip.has(el.tagName.toUpperCase()) || hidden(el)) return;
      if (el.matches(interactive)) {
        const id = `e${++count}`;
        el.setAttribute('data-happier-ref', id);
        let line = `[ref=${id}] ${roleOf(el)} "${labelOf(el)}"`;
        if ('value' in el && el.value && el.tagName !== 'BUTTON') line += ` value="${clean(String(el.value)).slice(0, 140)}"`;
        if (el.type === 'checkbox' || el.type === 'radio') line += el.checked ? ' [checked]' : ' [unchecked]';
        if (el.disabled) line += ' [disabled]';
        if (el.tagName === 'A' && el.href) line += ` -> ${el.getAttribute('href').slice(0, 200)}`;
        push(depth, line);
        if (el.tagName === 'SELECT') {
          for (const option of el.options) push(depth + 1, `option "${clean(option.text)}"${option.selected ? ' [selected]' : ''}`);
        }
        return;
      }
      const tag = el.tagName;
      if (/^H[1-6]$/.test(tag)) { push(depth, `${'#'.repeat(Number(tag[1]))} ${clean(el.innerText).slice(0, 200)}`); return; }
      if (tag === 'IMG') { const alt = clean(el.getAttribute('alt')); if (alt) push(depth, `img "${alt.slice(0, 140)}"`); return; }
      const nested = ['UL', 'OL', 'TABLE', 'FORM', 'NAV', 'DIALOG', 'SECTION', 'ARTICLE', 'MAIN', 'ASIDE', 'HEADER', 'FOOTER'].includes(tag);
      if (tag === 'LI') push(depth, '-');
      for (const child of el.childNodes) walk(child, depth + (nested || tag === 'LI' ? 1 : 0));
      if (el.shadowRoot) for (const child of el.shadowRoot.childNodes) walk(child, depth + 1);
    };
    walk(document.body || document.documentElement, 0);
    return { text: lines.join('\\n'), truncated };
    """

    /// Arguments: `ref`, `selector`.
    static let click = resolve + """
    const el = resolveTarget();
    if (!el) return { error: 'not_found' };
    el.scrollIntoView({ block: 'center', inline: 'center' });
    const rect = el.getBoundingClientRect();
    const init = { bubbles: true, cancelable: true, composed: true, view: window, button: 0,
                   clientX: rect.left + rect.width / 2, clientY: rect.top + rect.height / 2 };
    el.dispatchEvent(new PointerEvent('pointerdown', init));
    el.dispatchEvent(new MouseEvent('mousedown', init));
    if (typeof el.focus === 'function') el.focus();
    el.dispatchEvent(new PointerEvent('pointerup', init));
    el.dispatchEvent(new MouseEvent('mouseup', init));
    el.click();
    return describe(el);
    """

    /// Arguments: `ref`, `selector`, `text`, `clear`, `submit`.
    static let type = resolve + """
    const el = (ref || selector) ? resolveTarget() : document.activeElement;
    if (!el || el === document.body) return { error: 'not_found' };
    el.scrollIntoView({ block: 'center' });
    if (typeof el.focus === 'function') el.focus();
    if (el.isContentEditable) {
      if (clear) { document.execCommand('selectAll', false); document.execCommand('delete', false); }
      document.execCommand('insertText', false, text);
    } else if ('value' in el) {
      const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype
        : el instanceof HTMLSelectElement ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
      const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
      setter.call(el, clear || el instanceof HTMLSelectElement ? text : `${el.value}${text}`);
      el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: text }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    } else {
      return { error: 'not_editable' };
    }
    if (submit) {
      const key = { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true };
      const proceed = el.dispatchEvent(new KeyboardEvent('keydown', key));
      el.dispatchEvent(new KeyboardEvent('keypress', key));
      el.dispatchEvent(new KeyboardEvent('keyup', key));
      if (proceed && el.form) { if (el.form.requestSubmit) el.form.requestSubmit(); else el.form.submit(); }
    }
    return describe(el);
    """

    /// Arguments: `ref`, `selector`, `deltaX`, `deltaY`, `to`.
    static let scroll = resolve + """
    if (ref || selector) {
      const el = resolveTarget();
      if (!el) return { error: 'not_found' };
      el.scrollIntoView({ block: 'center', inline: 'nearest' });
    } else if (to === 'top') {
      window.scrollTo(0, 0);
    } else if (to === 'bottom') {
      window.scrollTo(0, document.documentElement.scrollHeight);
    } else {
      window.scrollBy(deltaX, deltaY);
    }
    return { scrollX: window.scrollX, scrollY: window.scrollY,
             scrollHeight: document.documentElement.scrollHeight, viewportHeight: window.innerHeight };
    """

    /// Arguments: `selector`, `text`. True once the condition holds.
    static let waitCondition = """
    if (typeof selector === 'string' && selector.length) return document.querySelector(selector) !== null;
    if (typeof text === 'string' && text.length) return (document.body ? document.body.innerText : '').includes(text);
    return false;
    """

    static let pageSize = """
    return { width: Math.max(document.documentElement.scrollWidth, window.innerWidth),
             height: Math.max(document.documentElement.scrollHeight, window.innerHeight) };
    """
}
