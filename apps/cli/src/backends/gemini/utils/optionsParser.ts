/**
 * Options Parser Utilities
 * 
 * Utilities for parsing and formatting XML options blocks from agent responses.
 * Used for extracting and formatting <options><option>...</option></options> blocks.
 */

export { hasIncompleteOptions, parseOptionsFromText } from '@happier-dev/protocol';

/**
 * Format options array as XML string
 * 
 * @param options - Array of option strings
 * @returns XML formatted string with <options> block
 */
export function formatOptionsXml(options: string[]): string {
  if (options.length === 0) {
    return '';
  }
  return '\n<options>\n' + options.map(opt => `    <option>${opt}</option>`).join('\n') + '\n</options>';
}

