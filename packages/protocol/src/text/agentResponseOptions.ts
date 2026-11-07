/**
 * Agents end a reply with an `<options><option>…</option></options>` block (see the base system
 * prompt) so the user can answer with one tap. Canonical parser for that block.
 */

/** True when the text opens an options block without closing it (e.g. a truncated reply). */
export function hasIncompleteOptions(text: string): boolean {
  const hasOpeningTag = /<options>/i.test(text);
  const hasClosingTag = /<\/options>/i.test(text);
  return hasOpeningTag && !hasClosingTag;
}

/** The text without its options block, and the non-empty option texts in order. */
export function parseOptionsFromText(text: string): { text: string; options: string[] } {
  const optionsRegex = /<options>\s*([\s\S]*?)\s*<\/options>/i;
  const match = text.match(optionsRegex);

  if (!match) {
    return { text: text.trim(), options: [] };
  }

  const optionsBlock = match[1] ?? '';
  const optionRegex = /<option>(.*?)<\/option>/gi;
  const options: string[] = [];
  let optionMatch: RegExpExecArray | null;

  while ((optionMatch = optionRegex.exec(optionsBlock)) !== null) {
    const optionText = (optionMatch[1] ?? '').trim();
    if (optionText) {
      options.push(optionText);
    }
  }

  return { text: text.replace(optionsRegex, '').trim(), options };
}
