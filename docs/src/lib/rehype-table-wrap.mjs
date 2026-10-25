// Wraps every Markdown table in `<div class="kix-table">` so the table can
// fill the article column while the wrapper scrolls it sideways on narrow
// screens. Styles live in src/styles/kix.css.
import { visit } from 'unist-util-visit';

export default function rehypeTableWrap() {
  return (tree) => {
    visit(tree, 'element', (node, index, parent) => {
      if (node.tagName !== 'table' || !parent || index === undefined) return;
      if (parent.type === 'element' && parent.properties?.className?.includes?.('kix-table')) return;
      parent.children[index] = {
        type: 'element',
        tagName: 'div',
        properties: { className: ['kix-table'] },
        children: [node],
      };
    });
  };
}
